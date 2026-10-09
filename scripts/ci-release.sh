#!/usr/bin/env bash
set -euo pipefail
: "${VERSION:?Provide an immutable release tag}"
[[ "$VERSION" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || { echo 'Invalid release tag' >&2; exit 1; }
checksum="$(awk -v version="$VERSION" '$1 == version {print $2}' release-checksums.txt)"
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || { echo "No verified checksum for $VERSION" >&2; exit 1; }
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
archive="$staging/media-maven.tar.gz"
curl -fsSL --retry 3 --connect-timeout 30 --max-time 300 -o "$archive" "https://github.com/gycrosskit/media/releases/download/$VERSION/media-maven.tar.gz"
echo "$checksum  $archive" | shasum -a 256 -c -
python3 - "$archive" "$staging/maven" <<'EXTRACT'
import sys, tarfile
from pathlib import Path
archive, destination = sys.argv[1:]
root = Path(destination).resolve()
with tarfile.open(archive) as bundle:
    for item in bundle.getmembers():
        assert item.isfile() or item.isdir(), f"Unexpected archive member: {item.name}"
        assert (root / item.name).resolve().is_relative_to(root), item.name
    bundle.extractall(root)
EXTRACT
python3 scripts/check-maven.py "$staging/maven" com.github.gycrosskit.media "$VERSION" media-core,media-kuikly ios_arm64,ios_x64,ios_simulator_arm64,ohos_arm64
# 标签必须解析为不可变发布提交；不把当前 PR 的 SHA 当成已发布版本。
commit="$(git ls-remote https://github.com/gycrosskit/media.git "refs/tags/$VERSION" "refs/tags/$VERSION^{}" | awk '$2 ~ /\^\{\}$/ {peeled=$1} $2 !~ /\^\{\}$/ {direct=$1} END {print peeled ? peeled : direct}')"
publications=media-core,media-core-android,media-core-iosarm64,media-core-iosx64,media-core-iossimulatorarm64,media-core-ohosarm64,media-kuikly,media-kuikly-ohosarm64
case "$VERSION" in
  0.1.[0-8]) ;;
  *) publications=media-core,media-core-android,media-core-iosarm64,media-core-iosx64,media-core-iossimulatorarm64,media-core-ohosarm64,media-kuikly,media-kuikly-android,media-kuikly-iosarm64,media-kuikly-iosx64,media-kuikly-iossimulatorarm64,media-kuikly-ohosarm64 ;;
esac
python3 scripts/check-public-maven.py --repo media --version "$VERSION" --commit "$commit" \
  --expected-publications "$publications" --output-dir "${CI_DIAGNOSTICS_DIR:-ci-diagnostics}/public"
