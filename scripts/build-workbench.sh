#!/bin/bash
# Build the double-clickable manual workbench app. No installs, no Homebrew needed
# at launch: the pinned libopus and its license are copied into the bundle.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# Optional output directory argument (relative to repo or absolute). The prior
# candidate directory is never touched unless explicitly named.
out="${1:-$root/build/manual-workbench-20261117}"
case "$out" in /*) ;; *) out="$root/$out";; esac
app="$out/BridgeWorkbench.app"
opus="/opt/homebrew/Cellar/opus/1.6.1/lib/libopus.0.dylib"
lic="/opt/homebrew/Cellar/opus/1.6.1/COPYING"
pinned="98dcd3cc62c6cf913b789051536ab246c56cc163c74bd8b4968ac467ec74b68b"
mkdir -p "$out"
if [ -e "$app" ]; then
  mv "$app" "$out/BridgeWorkbench.previous-$(date +%Y%m%d-%H%M%S)-$$.app"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
actual="$(shasum -a 256 "$opus" | awk '{print $1}')"
[ "$actual" = "$pinned" ] || { echo "pinned libopus hash mismatch" >&2; exit 2; }
cp "$opus" "$app/Contents/Resources/libopus.0.dylib"
cp "$lic" "$app/Contents/Resources/OPUS-LICENSE.txt"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.zivoice.bridge-workbench</string>
<key>CFBundleName</key><string>Bridge 手动工作台</string>
<key>CFBundleDisplayName</key><string>Bridge 手动工作台</string>
<key>CFBundleExecutable</key><string>BridgeWorkbench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>0.2</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>仅在你点击“扫描”后连接你指定的录音豆，用于手动连接与试音测试；不解绑、不刷固件、不读取历史录音。</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -O -o "$app/Contents/MacOS/BridgeWorkbench" "$root"/native/pilot/*.swift "$root/tests/PilotTests.swift" \
  -framework CoreBluetooth -framework AVFoundation -framework CoreAudio -framework CryptoKit -framework AppKit
# Sign only the app main executable. Signing the dylib would change its bytes and
# break the pinned SHA-256 integrity check that LiveOpus performs at runtime.
codesign --force --sign - "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/BridgeWorkbench" self-test | tee "$out/self-test.jsonl"
"$app/Contents/MacOS/BridgeWorkbench" ui-smoke | tee "$out/ui-smoke.jsonl"
python3 - "$root" "$out" "$pinned" <<'PY'
import hashlib, json, subprocess, sys, datetime, glob, os
root, out, pinned = sys.argv[1], sys.argv[2], sys.argv[3]
def sha(p):
    return hashlib.sha256(open(p,'rb').read()).hexdigest()
app = os.path.join(out, "BridgeWorkbench.app")
files = sorted(glob.glob(os.path.join(root,"native/pilot/*.swift")) + [os.path.join(root,"tests/PilotTests.swift"),os.path.join(root,"scripts/build-workbench.sh")])
manifest = {
  "created": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
  "git_head": subprocess.run(["git","-C",root,"rev-parse","HEAD"],capture_output=True,text=True).stdout.strip(),
  "app": os.path.relpath(app, root),
  "launch": "double-click the app (no arguments); BLE starts only after pressing 扫描",
  "bundled_opus": {"path":"Contents/Resources/libopus.0.dylib","sha256":sha(app+"/Contents/Resources/libopus.0.dylib"),"pinned":pinned},
  "license": "Contents/Resources/OPUS-LICENSE.txt",
  "source_sha256": {p: sha(p) for p in files},
  "checks": "self-test.jsonl / ui-smoke.jsonl in this directory",
  "not_run": "no hardware connection/recording; no audio saved; no install; no ZiVoice change; no commit/push",
}
json.dump(manifest, open(os.path.join(out,"manifest.json"),"w"), indent=2, ensure_ascii=False)
print("manifest written")
PY
