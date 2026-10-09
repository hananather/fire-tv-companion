#!/bin/zsh
set -eu

task_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
app_dir="${1:-$task_dir/dist/Fire TV Companion.app}"
task_arch="$(uname -m)"
if [[ "$task_arch" != arm64 ]]; then
  print -u2 -- "This build supports Apple-silicon Macs."
  exit 1
fi
task_tmp_root="${TMPDIR:-/tmp}"
build_dir="$(mktemp -d "${task_tmp_root%/}/fire-tv-companion.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT

mkdir -p "$build_dir/Fire TV Companion.app/Contents/MacOS"
compiler_flags=(-swift-version 5 -O -target arm64-apple-macosx15.0 -sdk "$(xcrun --show-sdk-path)" -module-cache-path "$build_dir/module-cache")
swift_bin="$(xcrun --find swiftc)"
swift_headers="$(cd -- "$(dirname -- "$swift_bin")/../include/swift" && pwd)"
if [[ -f "$swift_headers/bridging.modulemap" && -f "$swift_headers/module.modulemap" ]]; then
  # Some Command Line Tools upgrades leave a second SwiftBridging definition.
  # Hide the obsolete map only within this build's virtual filesystem.
  : > "$build_dir/empty.modulemap"
  python3 - "$swift_headers/module.modulemap" "$build_dir" <<'PY'
import json
import pathlib
import sys
legacy, temporary = sys.argv[1:]
overlay = {"version": 0, "case-sensitive": "false", "roots": [
    {"type": "file", "name": legacy,
     "external-contents": str(pathlib.Path(temporary) / "empty.modulemap")},
    {"type": "file", "name": legacy.replace("/include/swift/", "/include/Swift/"),
     "external-contents": str(pathlib.Path(temporary) / "empty.modulemap")},
]}
(pathlib.Path(temporary) / "overlay.json").write_text(json.dumps(overlay))
PY
  compiler_flags+=(-vfsoverlay "$build_dir/overlay.json")
fi
if [[ "${1:-}" == --test ]]; then
  "$swift_bin" "${compiler_flags[@]}" -framework AppKit -framework CryptoKit -framework Security -framework Network \
    "$task_dir/Core.swift" "$task_dir/CoreTests.swift" -o "$build_dir/CoreTests"
  "$build_dir/CoreTests"
  exit
fi
source_files=("$task_dir/app.swift" "$task_dir/Core.swift" "$task_dir/VideoPlayer.swift" "$task_dir/AudioRouting.swift")
if [[ -f "$task_dir/Dashboard.swift" ]]; then source_files+=("$task_dir/Dashboard.swift"); fi
"$swift_bin" "${compiler_flags[@]}" \
  -framework AppKit -framework CryptoKit -framework Security -framework Network \
  -framework AVKit -framework AVFoundation -framework CoreAudio -framework IOKit -framework WebKit \
  "${source_files[@]}" \
  -o "$build_dir/Fire TV Companion.app/Contents/MacOS/Fire TV Companion"

cat > "$build_dir/Fire TV Companion.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Fire TV Companion</string>
  <key>CFBundleIdentifier</key><string>local.hanan.fire-tv-companion</string>
  <key>CFBundleName</key><string>Fire TV Companion</string>
  <key>CFBundleDisplayName</key><string>Fire TV Companion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Find and pair with the Fire TV you select on your Wi-Fi network.</string>
  <key>NSBonjourServices</key><array><string>_airplay._tcp</string></array>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

plutil -lint "$build_dir/Fire TV Companion.app/Contents/Info.plist"
mkdir -p "$build_dir/Fire TV Companion.app/Contents/Resources"
cp "$task_dir/test-video.mp4" "$build_dir/Fire TV Companion.app/Contents/Resources/test-video.mp4"
codesign --force --sign - "$build_dir/Fire TV Companion.app"
mkdir -p "$(dirname -- "$app_dir")"
ditto "$build_dir/Fire TV Companion.app" "$app_dir"
codesign --verify --strict "$app_dir"
print -r -- "Built $app_dir"
