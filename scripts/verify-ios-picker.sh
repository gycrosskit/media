#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
target="$(uname -m)-apple-ios14.0-simulator"
output="$PWD/build/ios-picker-check"
app="$output/PickerCheck.app"
mkdir -p "$app/Frameworks" "$output/module"
xcrun --sdk iphonesimulator swiftc -emit-library -emit-module -enable-testing -module-name GycMedia \
    -target "$target" -sdk "$sdk" -emit-module-path "$output/module/GycMedia.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libGycMedia.dylib \
    iosApp/Sources/GycMedia/*.swift -o "$app/Frameworks/libGycMedia.dylib"
xcrun --sdk iphonesimulator swiftc -parse-as-library -target "$target" -sdk "$sdk" -I "$output/module" \
    -L "$app/Frameworks" -lGycMedia -Xlinker -rpath -Xlinker @executable_path/Frameworks \
    iosApp/Tests/PickerLifecycleCheck.swift -o "$app/PickerCheck"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.gycrosskit.media.picker-check</string>
<key>CFBundleExecutable</key><string>PickerCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>PickerCheck</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSRequiresIPhoneOS</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Frameworks/libGycMedia.dylib" "$app" >/dev/null
xcrun simctl install "${MEDIA_SIMULATOR:-booted}" "$app"
xcrun simctl launch --console --terminate-running-process "${MEDIA_SIMULATOR:-booted}" io.github.gycrosskit.media.picker-check | tee "$output/result.log"
rg -q '^PASS: Picker ownership' "$output/result.log"
