#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./gradlew :media-core:compileDebugKotlinAndroid :media-core:testDebugUnitTest :media-core:linkDebugFrameworkIosSimulatorArm64 :media-core:compileKotlinOhosArm64 :media-kuikly:compileKotlinOhosArm64 --no-daemon
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p build/swift-module
xcrun swiftc -emit-module -module-name GycMedia -target arm64-apple-ios14.0-simulator -sdk "$sdk" -emit-module-path build/swift-module/GycMedia.swiftmodule iosApp/Sources/GycMedia/*.swift
xcrun swiftc -typecheck -target arm64-apple-ios14.0-simulator -sdk "$sdk" -I build/swift-module -F media-core/build/bin/iosSimulatorArm64/debugFramework iosApp/KmpMediaBridge.swift
