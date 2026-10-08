#!/usr/bin/env python3
"""Native 下载缓存绑定工具链和 Xcode；预热不编译组件业务源码。"""
import argparse
import configparser
import hashlib
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile


TARGETS = {
    'ios_arm64': ('iosArm64', 'linkDebugFrameworkIosArm64'),
    'ios_x64': ('iosX64', 'linkDebugFrameworkIosX64'),
    'ios_simulator_arm64': ('iosSimulatorArm64', 'linkDebugFrameworkIosSimulatorArm64'),
    'ohos_arm64': ('ohosArm64', 'linkDebugSharedOhosArm64'),
}


def configuration(root):
    file = root / 'gradle/native-toolchain.properties'
    parser = configparser.ConfigParser()
    parser.read_string('[native]\n' + file.read_text())
    config = parser['native']
    version = config['kotlin']
    targets = config['targets'].split(',')
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?', version):
        raise ValueError('Invalid Kotlin/Native version')
    if not targets or len(set(targets)) != len(targets) or any(t not in TARGETS for t in targets):
        raise ValueError('Invalid Native cache targets')
    # 防止改了组件/consumer 编译器，却忘记更新工具链清单而持续恢复旧 key。
    versions = set()
    for relative in ['build.gradle.kts', 'gradle/libs.versions.toml',
                     'verification/build.gradle.kts', 'verification/gradle/build.gradle.kts',
                     'verification/consumer/build.gradle.kts', 'verification-consumer/build.gradle.kts',
                     'verification-consumer/gradle/libs.versions.toml']:
        path = root / relative
        if path.exists():
            text = path.read_text()
            versions.update(re.findall(r'kotlin\("multiplatform"\)\s+version\s+"([^"]+)"', text))
            versions.update(re.findall(r'^kotlin\s*=\s*"([^"]+)"', text, re.M))
    if versions != {version}:
        raise ValueError(f'Native cache Kotlin {version} differs from project versions {sorted(versions)}')
    return file, version, targets


def cache_key(root, sdk):
    file, _, _ = configuration(root)
    digest = hashlib.sha256(file.read_bytes() + Path(__file__).read_bytes() + sdk.encode()).hexdigest()
    return f'konan-v2-{platform.system()}-{platform.machine()}-{digest}'


def warm(root):
    _, version, targets = configuration(root)
    if os.environ.get('GITHUB_ACTIONS') == 'true' and (
        os.environ.get('GITHUB_REF') != 'refs/heads/main' or
        os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'
    ):
        raise ValueError('Only an explicit main dispatch may warm the trusted cache')
    with tempfile.TemporaryDirectory(prefix='native-cache-') as temporary:
        probe = Path(temporary)
        (probe / 'settings.gradle.kts').write_text('''pluginManagement { repositories {
    maven("https://maven.eazytec-cloud.com/nexus/repository/maven-public") {
        content { includeVersionByRegex(".*", ".*", ".*-1\\\\.0\\\\.0") }
    }
    gradlePluginPortal(); mavenCentral()
} }
dependencyResolutionManagement { repositories {
    maven("https://maven.eazytec-cloud.com/nexus/repository/maven-public") {
        content { includeVersionByRegex(".*", ".*", ".*-1\\\\.0\\\\.0") }
    }
    mavenCentral()
} }
rootProject.name = "native-toolchain-warmup"
''')
        declarations = '\n'.join(
            f'    {TARGETS[t][0]}().binaries.' + ('sharedLib()' if t == 'ohos_arm64' else 'framework()')
            for t in targets)
        (probe / 'build.gradle.kts').write_text(
            f'plugins {{ kotlin("multiplatform") version "{version}" }}\nkotlin {{\n{declarations}\n}}\n')
        source = probe / 'src/commonMain/kotlin'
        source.mkdir(parents=True)
        (source / 'Warmup.kt').write_text('fun nativeToolchainWarmup(): Int = 42\n')
        subprocess.run(['bash', str(root / 'gradlew'), '--init-script',
                        str(root / 'scripts/ci-repositories.gradle'), '-p', str(probe),
                        *(TARGETS[t][1] for t in targets), '--no-daemon', '--max-workers=1', '--info'],
                       cwd=root, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.key:
        sdk = subprocess.check_output(['xcodebuild', '-version'], text=True)
        print('key=' + cache_key(root, sdk))
    else:
        warm(root)


if __name__ == '__main__':
    main()
