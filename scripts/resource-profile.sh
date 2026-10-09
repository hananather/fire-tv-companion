#!/bin/zsh
set -eu

task_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp/}resource-profile.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
swift_bin="$(xcrun --find swiftc)"
compiler_flags=(-O -target "$(uname -m)-apple-macosx13.0" -sdk "$(xcrun --show-sdk-path)" -module-cache-path "$build_dir/module-cache")
swift_headers="$(cd -- "$(dirname -- "$swift_bin")/../include/swift" && pwd)"
if [[ -f "$swift_headers/bridging.modulemap" && -f "$swift_headers/module.modulemap" ]]; then
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
"$swift_bin" "${compiler_flags[@]}" -framework IOKit -framework CoreGraphics -framework AppKit \
  "$task_dir/ResourceProfile.swift" -o "$build_dir/resource-profile"
if [[ "${1:-}" == --build-helper ]]; then
  if [[ $# != 2 ]]; then
    print -u2 -- "Use --build-helper with one destination path."
    exit 2
  fi
  cp "$build_dir/resource-profile" "$2"
  chmod +x "$2"
  print -- "Built the passive resource profiler."
  exit
fi
"$build_dir/resource-profile" "$@"
