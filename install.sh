#!/bin/zsh
set -eu
task_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
task_app="$HOME/Applications/Fire TV Companion.app"
"$task_dir/build.sh" "$task_app"
/usr/bin/open "$task_app"
