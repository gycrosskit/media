#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
collect_picker_failure() {
    local picker_exit=$?
    if [[ "$picker_exit" == 0 ]]; then return; fi
    set +e
    mkdir -p ci-diagnostics
    shopt -s nullglob
    for report in "$HOME"/Library/Logs/DiagnosticReports/PickerCheck-*.ips "$HOME"/Library/Logs/DiagnosticReports/PickerCheck-*.crash; do
        cp "$report" "ci-diagnostics/$(basename "$report").txt"
    done
    xcrun simctl spawn "${MEDIA_SIMULATOR:-booted}" log show --last 5m --style compact --predicate 'process == "PickerCheck"' > ci-diagnostics/picker-simulator.txt 2>&1
    return "$picker_exit"
}
trap collect_picker_failure EXIT
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
    iosApp/Tests/*.swift -o "$app/PickerCheck"
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
xcrun simctl launch --console --terminate-running-process "${MEDIA_SIMULATOR:-booted}" io.github.gycrosskit.media.picker-check 2>&1 | tee "$output/result.log" || {
    picker_failure=("$?" "${PIPESTATUS[@]}")
    printf 'FAIL: Picker launch=%s tee=%s\n' "${picker_failure[1]}" "${picker_failure[2]}" >&2
    exit "${picker_failure[0]}"
}
grep -q '^PASS: Picker ownership' "$output/result.log" || {
    printf 'FAIL: Picker PASS marker missing\n' >&2
    exit 1
}
