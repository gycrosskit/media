#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
products=${1:?Pass the real Simulator Pod build Products directory}
case "$(uname -m)" in
  arm64) target=IosSimulatorArm64; directory=iosSimulatorArm64 ;;
  x86_64) target=IosX64; directory=iosX64 ;;
  *) echo "Unsupported macOS architecture" >&2; exit 1 ;;
esac
# 只在仓库内 staging 写入当前源码候选；不触发远程发布。
bash gradlew --init-script "$PWD/scripts/ci-repositories.gradle" \
  :media-core:publishKotlinMultiplatformPublicationToReleaseRepository \
  :media-core:publish${target}PublicationToReleaseRepository \
  :media-kuikly:publishKotlinMultiplatformPublicationToReleaseRepository \
  :media-kuikly:publish${target}PublicationToReleaseRepository \
  --no-daemon --max-workers=1
bash gradlew --init-script "$PWD/scripts/ci-repositories.gradle" -p verification-consumer \
  linkDebugFramework${target} -PmediaMavenRepo="$PWD/build/release-maven" \
  -PkuiklyRenderFrameworkDir="$products" --no-daemon --max-workers=1
xcrun swiftc -typecheck -target "$(uname -m)-apple-ios15.0-simulator" \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -F "$products" \
  -F "verification-consumer/build/bin/$directory/debugFramework" \
  verification-consumer/NativeModuleAssembly.swift
