#!/usr/bin/env bash
set -euo pipefail
repository="${1:?Pass the component repository name}"
[[ "$repository" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo 'Invalid repository name' >&2; exit 1; }
: "${VERSION:?JitPack must provide an immutable tag}"
checksum="$(awk -v version="$VERSION" '$1 == version {print $2}' release-checksums.txt)"
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || { echo "No verified archive checksum for $VERSION" >&2; exit 1; }
archive="${repository}-maven.tar.gz"
curl -fL --retry 3 -o "$archive" "https://github.com/gycrosskit/${repository}/releases/download/${VERSION}/${archive}"
echo "$checksum  $archive" | sha256sum -c -
mkdir -p "$HOME/.m2/repository" build/release-maven
tar -xzf "$archive" -C "$HOME/.m2/repository"
tar -xzf "$archive" -C build/release-maven
python3 jitpack-metadata.py "$HOME/.m2/repository/com/github/gycrosskit/${repository}" "build/release-maven/com/github/gycrosskit/${repository}"
