#!/usr/bin/env python3
"""只读核验指定不可变 JitPack 标签：公网身份、全部变体及实际 sidecar；不构建消费工程。"""
import argparse
import concurrent.futures
import hashlib
import io
import json
import re
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

HASHES = ('md5', 'sha1', 'sha256', 'sha512')
NAME = r'[A-Za-z0-9][A-Za-z0-9._-]*'
LICENSES = {
    'Apache-2.0': ('Apache License, Version 2.0', 'https://www.apache.org/licenses/LICENSE-2.0.txt'),
    'BSD-3-Clause': ('BSD 3-Clause License', 'https://opensource.org/licenses/BSD-3-Clause'),
}


def require(condition, detail):
    if not condition:
        raise ValueError(str(detail))


def get_bytes(url):
    # 仅访问公开端点，不读取 Token、Cookie 或本机 Maven 配置。
    request = urllib.request.Request(url, headers={'User-Agent': 'GYCrossKit-public-maven-check'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def validate_state(state, version, commit, publications):
    require(not version.upper().endswith('-SNAPSHOT'), 'A SNAPSHOT is not an immutable release')
    require(state.get('status') == 'ok' and state.get('isTag') is True and state.get('private') is False,
            'JitPack must report a public successful immutable tag')
    require(state.get('version') == version and state.get('commit') == commit, 'JitPack version/commit mismatch')
    actual = state.get('modules')
    require(isinstance(actual, list) and all(isinstance(item, str) for item in actual), 'Invalid JitPack inventory')
    require(len(actual) == len(set(actual)) and set(actual) == set(publications), 'Exact publication inventory mismatch')


def validate_component(component, group, module, repository, version):
    # JitPack 会将 GMM component 正规化成父组织/repo；只允许这一成对转换，不任意放宽 group/module。
    canonical = ('com.github.gycrosskit', repository)
    identity = (component.get('group'), component.get('module'))
    require(component.get('version') == version and identity in ((group, module), canonical),
            (module, 'Unexpected GMM identity', component))
    return identity == canonical and identity != (group, module)


def validate_file(item, data, url):
    require(isinstance(item.get('size'), int) and len(data) == item['size'], (url, 'Byte size mismatch'))
    for algorithm in HASHES:
        require(item.get(algorithm) == hashlib.new(algorithm, data).hexdigest(), (url, 'Declared ' + algorithm + ' mismatch'))
    if Path(item['name']).suffix.lower() in ('.aar', '.jar', '.klib', '.zip'):
        with zipfile.ZipFile(io.BytesIO(data)) as packed:
            require(packed.testzip() is None, (url, 'ZIP CRC mismatch'))
            require(not any(Path(name).name.startswith('._') for name in packed.namelist()), (url, 'AppleDouble member'))


def check_sidecars(url, data, fetch):
    result = {'url': url, 'verified': [], 'notAvailable': []}
    for algorithm in HASHES:
        try:
            raw = fetch(url + '.' + algorithm)
        except urllib.error.HTTPError as error:
            if error.code == 404 and algorithm in ('sha256', 'sha512'):
                result['notAvailable'].append(algorithm)
                continue
            raise
        # 不接受空响应、HTML 错误页或异常 digest；下载缺失与校验通过分开报告。
        text = raw.decode('ascii').strip().split()
        require(text and re.fullmatch(r'[0-9a-fA-F]{%d}' % (hashlib.new(algorithm).digest_size * 2), text[0]),
                (url, 'Invalid ' + algorithm + ' sidecar'))
        require(text[0].lower() == hashlib.new(algorithm, data).hexdigest(), (url, algorithm + ' sidecar mismatch'))
        result['verified'].append(algorithm)
    return result


def audit(repository, version, commit, publications, output, group=None, license_name='Apache-2.0', fetch=get_bytes):
    require(re.fullmatch(NAME, repository) and re.fullmatch(NAME, version), 'Invalid repository/version')
    require(re.fullmatch(r'[0-9a-f]{40}', commit), 'Expected a full lowercase commit SHA')
    require(publications and len(publications) == len(set(publications)) and
            all(re.fullmatch(NAME, item) for item in publications), 'Invalid exact publication inventory')
    group = group or 'com.github.gycrosskit.' + repository
    require(re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+', group), 'Invalid public Maven group')
    require(license_name in LICENSES, 'Unsupported expected license')
    base = 'https://jitpack.io/' + group.replace('.', '/') + '/'
    state_url = f'https://jitpack.io/api/builds/com.github.gycrosskit/{repository}/{version}'
    state = json.loads(fetch(state_url))
    validate_state(state, version, commit, publications)
    output = Path(output)
    require(not output.exists() or (output.is_dir() and not any(output.iterdir())), 'Output directory must be new or empty')
    output.mkdir(parents=True, exist_ok=True)
    (output / 'jitpack-state.json').write_text(json.dumps(state, indent=2) + '\n')
    publication_set = set(publications)
    expected_license, expected_license_url = LICENSES[license_name]
    ns = {'m': 'http://maven.apache.org/POM/4.0.0'}

    def inspect(module):
        directory = output / module
        directory.mkdir()
        prefix = f'{base}{module}/{version}/{module}-{version}'
        metadata_url = prefix + '.module'
        raw = fetch(metadata_url)
        metadata = json.loads(raw)
        transformed = validate_component(metadata['component'], group, module, repository, version)
        (directory / (module + '.module')).write_bytes(raw)
        sidecars = [check_sidecars(metadata_url, raw, fetch)]
        pom = fetch(prefix + '.pom')
        parsed = ET.fromstring(pom)
        for tag, expected in [('groupId', group), ('artifactId', module), ('version', version),
                              ('licenses/m:license/m:name', expected_license),
                              ('licenses/m:license/m:url', expected_license_url),
                              ('licenses/m:license/m:distribution', 'repo')]:
            require(parsed.findtext('m:' + tag, namespaces=ns) == expected, (module, 'POM ' + tag, expected))
        for dependency in parsed.findall('m:dependencies/m:dependency', ns):
            dependency_group = dependency.findtext('m:groupId', namespaces=ns)
            dependency_module = dependency.findtext('m:artifactId', namespaces=ns)
            if dependency_group == group or dependency_module in publication_set:
                require(dependency_group == group and dependency_module in publication_set and
                        dependency.findtext('m:version', namespaces=ns) == version, (module, 'POM internal dependency mismatch'))
        (directory / (module + '.pom')).write_bytes(pom)
        sidecars.append(check_sidecars(prefix + '.pom', pom, fetch))
        variants = metadata.get('variants')
        require(isinstance(variants, list) and variants and
                len({variant['name'] for variant in variants}) == len(variants), (module, 'Invalid variants'))
        downloaded = {}
        for variant in variants:
            available = variant.get('available-at')
            if available:
                target = available.get('module')
                require(available.get('group') == group and available.get('version') == version and
                        target in publication_set, (module, 'available-at identity mismatch', available))
                target_url = f'{base}{target}/{version}/{target}-{version}.module'
                require(urllib.parse.urljoin(metadata_url, available['url']) == target_url,
                        (module, 'available-at URL mismatch', available))
            for dependency in variant.get('dependencies', []) + variant.get('dependencyConstraints', []):
                if dependency.get('group') == group or dependency.get('module') in publication_set:
                    spec = dependency.get('version', {})
                    require(dependency.get('group') == group and dependency.get('module') in publication_set and
                            spec.get('requires') == version and
                            all(value == version for key, value in spec.items() if key in ('strictly', 'prefers')) and
                            not spec.get('rejects'), (module, 'GMM internal dependency mismatch', dependency))
            for item in variant.get('files', []):
                name = item.get('name', '')
                require(re.fullmatch(NAME, name), (module, 'Invalid variant file name', name))
                url = urllib.parse.urljoin(metadata_url, item['url'])
                require(url == f'{base}{module}/{version}/{name}', (module, 'Variant file URL mismatch', url))
                if url not in downloaded:
                    data = fetch(url)
                    downloaded[url] = data
                    (directory / name).write_bytes(data)
                    sidecars.append(check_sidecars(url, data, fetch))
                # 同 URL 的每个声明都核验，不能由下载去重掩盖互相冲突的 hash/size。
                validate_file(item, downloaded[url], url)
        return {'module': module, 'variants': variants, 'component': metadata['component'],
                'jitpackComponentRewrite': transformed,
                'files': {url: hashlib.sha256(data).hexdigest() for url, data in downloaded.items()}, 'sidecars': sidecars}

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(inspect, publications))
    by_module = {result['module']: result for result in results}
    for result in results:
        for variant in result['variants']:
            target = variant.get('available-at')
            if target:
                require(any(item['name'] == variant['name'] for item in by_module[target['module']]['variants']),
                        (result['module'], 'available-at variant not present', variant['name']))
    files = {url for result in results for url in result['files']}
    missing = [{'url': item['url'], 'algorithms': item['notAvailable']}
               for result in results for item in result['sidecars'] if item['notAvailable']]
    proof = {'repository': repository, 'publicGroup': group, 'version': version, 'commit': commit,
             'moduleCount': len(results), 'uniqueFileCount': len(files), 'modules': results,
             'publicHigherSidecarsComplete': not missing, 'missingPublicHigherSidecars': missing,
             'scope': 'Public immutable JitPack state, exact publications, POM/license and GMM identity, every variant byte size/four declared hashes/ZIP CRC, available-at/internal versions; POM/module/variant MD5/SHA1 sidecars required. SHA256/SHA512 HTTP404 are missing, never verified. No consumer build, Native/device/Swift/OHPM acceptance; rewritten component.url is not a consumer coordinate.'}
    (output / 'proof.json').write_text(json.dumps(proof, indent=2) + '\n')
    return proof


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--commit', required=True, help='不可变标签所指向的完整40位小写 Git SHA')
    parser.add_argument('--group', help='实际公网消费 group；默认 com.github.gycrosskit.<repo>')
    parser.add_argument('--expected-publications', required=True, help='精确 publication CSV，不使用本机 staging 推断公网 inventory')
    parser.add_argument('--output-dir', type=Path, required=True, help='新的空目录，全部要求通过后才生成 proof.json')
    parser.add_argument('--license', choices=tuple(LICENSES), default='Apache-2.0')
    args = parser.parse_args()
    proof = audit(args.repo, args.version, args.commit, args.expected_publications.split(','), args.output_dir, args.group, args.license)
    missing = sum(len(item['algorithms']) for item in proof['missingPublicHigherSidecars'])
    print(f"{args.repo} {args.version}: {proof['moduleCount']} publications, {proof['uniqueFileCount']} unique variant files verified; "
          f"public POM/module/variant MD5/SHA1 verified; SHA256/SHA512 HTTP404 missing (not verified): {missing}")


if __name__ == '__main__':
    main()
