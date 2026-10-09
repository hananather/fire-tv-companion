#!/bin/zsh
set -eu
task_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
task_app="$HOME/Applications/Fire TV Companion.app"
if /usr/bin/pgrep -f '/Fire TV Companion[.]app/Contents/MacOS/Fire TV Companion( |$)' >/dev/null; then
  print -u2 -- "Quit Fire TV Companion from its menu, then run the installer again."
  exit 1
fi
"$task_dir/build.sh" "$task_app"
/usr/bin/open "$task_app"
