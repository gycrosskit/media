#!/usr/bin/env python3
"""只读核验指定不可变 JitPack 标签：公网身份、全部变体及实际 sidecar；不构建消费工程。"""
import argparse
import concurrent.futures
import hashlib
import io
import http.client
import json
import re
import ssl
import sys
import time
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
    for attempt in range(3):
        try:
            deadline = time.monotonic() + 90
            with urllib.request.urlopen(request, timeout=15) as response:
                chunks = []
                expected = response.headers.get('Content-Length')
                length = 0
                while True:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('Public download exceeded 90 seconds: ' + url)
                    chunk = response.read1(65536)
                    if not chunk:
                        if expected and expected.isdigit() and length != int(expected):
                            raise http.client.IncompleteRead(b'', int(expected) - length)
                        return b''.join(chunks)
                    chunks.append(chunk)
                    length += len(chunk)
        except urllib.error.HTTPError as error:
            print(json.dumps({'url': url, 'attempt': attempt + 1, 'http_status': error.code}), file=sys.stderr)
            if error.code not in (408, 429, 500, 502, 503, 504) or attempt == 2:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.IncompleteRead, ssl.SSLEOFError) as error:
            print(json.dumps({'url': url, 'attempt': attempt + 1, 'type': type(error).__name__, 'error': str(error)}), file=sys.stderr)
            if isinstance(getattr(error, 'reason', None), ssl.SSLCertVerificationError) or attempt == 2:
                raise
        time.sleep(attempt + 1)


def ready_state(url, version, commit, publications, output, fetch, wait_seconds=0, poll_seconds=10, bootstrap_url=None):
    deadline = time.monotonic() + wait_seconds
    attempt = 0
    triggered = False
    while True:
        attempt += 1
        try:
            raw = fetch(url)
        except Exception as error:
            (output / 'jitpack-state-error.json').write_text(json.dumps({
                'attempt': attempt, 'type': type(error).__name__, 'error': str(error)}, indent=2) + '\n')
            raise
        # 先持久化原响应，再解码与校验，首失败不能丢失。
        (output / ('jitpack-state-%03d.json' % attempt)).write_bytes(raw)
        state = json.loads(raw)
        (output / 'jitpack-state.json').write_bytes(raw)
        with (output / 'jitpack-state-history.jsonl').open('a') as history:
            history.write(json.dumps({'attempt': attempt, 'status': state.get('status'),
                                      'elapsed_remaining': max(0, round(deadline - time.monotonic(), 3))}) + '\n')
        # 只等待明确未就绪状态；身份/清单/摘要不匹配和真正构建失败立即失败。
        if str(state.get('status', '')).lower() not in ('none', 'building', 'queued'):
            validate_state(state, version, commit, publications)
            return state
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            validate_state(state, version, commit, publications)
        if str(state.get('status', '')).lower() == 'none' and bootstrap_url and not triggered:
            # 只查询 API 不会发起新构建；请求精确 publication POM 一次，不删除/重建已有标签。
            triggered = True
            try:
                result = {'url': bootstrap_url, 'received_bytes': len(fetch(bootstrap_url))}
            except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.IncompleteRead) as error:
                result = {'url': bootstrap_url, 'type': type(error).__name__, 'error': str(error)}
                if isinstance(error, urllib.error.HTTPError) and error.code not in (404, 408, 429, 500, 502, 503, 504):
                    (output / 'jitpack-trigger.json').write_text(json.dumps(result, indent=2) + '\n')
                    raise
                if isinstance(getattr(error, 'reason', None), ssl.SSLCertVerificationError):
                    (output / 'jitpack-trigger.json').write_text(json.dumps(result, indent=2) + '\n')
                    raise
            (output / 'jitpack-trigger.json').write_text(json.dumps(result, indent=2) + '\n')
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            validate_state(state, version, commit, publications)
        time.sleep(min(poll_seconds, remaining))


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


def audit(repository, version, commit, publications, output, group=None, license_name='Apache-2.0', fetch=get_bytes,
          wait_seconds=0, poll_seconds=10):
    require(re.fullmatch(NAME, repository) and re.fullmatch(NAME, version), 'Invalid repository/version')
    require(re.fullmatch(r'[0-9a-f]{40}', commit), 'Expected a full lowercase commit SHA')
    require(publications and len(publications) == len(set(publications)) and
            all(re.fullmatch(NAME, item) for item in publications), 'Invalid exact publication inventory')
    group = group or 'com.github.gycrosskit.' + repository
    require(re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+', group), 'Invalid public Maven group')
    require(license_name in LICENSES, 'Unsupported expected license')
    base = 'https://jitpack.io/' + group.replace('.', '/') + '/'
    state_url = f'https://jitpack.io/api/builds/com.github.gycrosskit/{repository}/{version}'
    output = Path(output)
    require(not output.exists() or (output.is_dir() and not any(output.iterdir())), 'Output directory must be new or empty')
    output.mkdir(parents=True, exist_ok=True)
    first = publications[0]
    ready_state(state_url, version, commit, publications, output, fetch, wait_seconds, poll_seconds,
                bootstrap_url=f'{base}{first}/{version}/{first}-{version}.pom')
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
    parser.add_argument('--wait-seconds', type=int, default=300, help='只等待明确未就绪状态，最多300秒；0立即校验')
    args = parser.parse_args()
    if not 0 <= args.wait_seconds <= 300:
        parser.error('--wait-seconds must be between 0 and 300')
    fresh_output = not args.output_dir.exists() or (args.output_dir.is_dir() and not any(args.output_dir.iterdir()))
    try:
        proof = audit(args.repo, args.version, args.commit, args.expected_publications.split(','), args.output_dir,
                      args.group, args.license, wait_seconds=args.wait_seconds)
    except Exception as error:
        # 不覆盖已有输出目录；错误收据不是通过证明。
        if fresh_output and args.output_dir.is_dir() and not (args.output_dir / 'proof.json').exists():
            (args.output_dir / 'error.json').write_text(json.dumps({
                'type': type(error).__name__, 'error': str(error), 'verified': False}, indent=2) + '\n')
        raise
    missing = sum(len(item['algorithms']) for item in proof['missingPublicHigherSidecars'])
    print(f"{args.repo} {args.version}: {proof['moduleCount']} publications, {proof['uniqueFileCount']} unique variant files verified; "
          f"public POM/module/variant MD5/SHA1 verified; SHA256/SHA512 HTTP404 missing (not verified): {missing}")


if __name__ == '__main__':
    main()
