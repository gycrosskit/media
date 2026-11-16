#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?Pass the immutable candidate version}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { echo 'Invalid version' >&2; exit 2; }
[[ ! -e build/release-maven && ! -e build/media-maven.tar.gz ]] || { echo "Candidate outputs already exist" >&2; exit 2; }
bash gradlew --init-script "$PWD/scripts/ci-repositories.gradle" publishAllPublicationsToReleaseRepository --no-daemon --max-workers=1 -Dorg.gradle.parallel=false "$@"
python3 scripts/jitpack-metadata.py build/release-maven
python3 release-pack.py build/release-maven build/media-maven.tar.gz "$VERSION"
shasum -a 256 build/media-maven.tar.gz > build/media-maven.tar.gz.sha256
