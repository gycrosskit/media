#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
products=${1:?Pass the real Simulator Pod build Products directory}
test -f "$products/GycMediaKuikly.framework/GycMediaKuikly"
test -f "$products/OpenKuiklyIOSRender.framework/OpenKuiklyIOSRender"
output="$PWD/build/kuikly-module-check"
app="$output/ModuleCheck.app"
mkdir -p "$app/Frameworks"
cp -R "$products/GycMediaKuikly.framework" "$products/OpenKuiklyIOSRender.framework" "$app/Frameworks/"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-ios15.0-simulator"   -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -F "$products"   -framework GycMediaKuikly -framework OpenKuiklyIOSRender   -Xlinker -rpath -Xlinker @executable_path/Frameworks   iosApp/KuiklyTests/ModuleLifecycleCheck.swift -o "$app/ModuleCheck"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.gycrosskit.media.module-check</string>
<key>CFBundleExecutable</key><string>ModuleCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>ModuleCheck</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSRequiresIPhoneOS</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Frameworks/GycMediaKuikly.framework" "$app/Frameworks/OpenKuiklyIOSRender.framework" "$app" >/dev/null
simulator=${KUIKLY_MODULE_SIMULATOR:-$(xcrun simctl list devices available -j | python3 -c 'import json,sys; devices=[d for rows in json.load(sys.stdin)["devices"].values() for d in rows if d.get("isAvailable") and d["name"].startswith("iPhone")]; print(next((d for d in devices if d["state"]=="Booted"), devices[0])["udid"])')}
xcrun simctl bootstatus "$simulator" -b
xcrun simctl install "$simulator" "$app"
touch "$output/launch-start"
launch_status=0
xcrun simctl launch --console --terminate-running-process "$simulator" io.github.gycrosskit.media.module-check 2>&1 | tee "$output/result.log" || launch_status=$?
echo "ModuleCheck launch pipeline exit: $launch_status"
if [[ "$launch_status" -ne 0 ]] || ! grep -q '^PASS: media receiver' "$output/result.log"; then
    echo "ModuleCheck failed or its required PASS result is missing" >&2
    xcrun simctl spawn "$simulator" log show --last 2m --style compact --predicate 'process == "ModuleCheck"' 2>&1 | tail -n 120 >&2 || true
    mkdir -p ci-diagnostics
    # 仅保存本次 app 新生成的报告，最多 3 份，每份 256 KiB；不改变失败结果。
    python3 - "$HOME/Library/Logs/DiagnosticReports" "$output/launch-start" <<'CRASH_REPORTS' || true
from pathlib import Path
import sys
folder, stamp = map(Path, sys.argv[1:])
reports = [p for p in folder.glob('ModuleCheck-*') if p.is_file() and p.stat().st_mtime_ns >= stamp.stat().st_mtime_ns]
for report in sorted(reports, key=lambda p: p.stat().st_mtime_ns, reverse=True)[:3]:
    with report.open('rb') as source:
        Path('ci-diagnostics', report.name + '.txt').write_bytes(source.read(262144))
CRASH_REPORTS
    exit 1
fi
