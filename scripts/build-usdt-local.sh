#!/bin/bash
set -euo pipefail
core_dir="$(cd "${1:?Usage: build-usdt-local.sh CORE_DIRECTORY [xcodebuild arguments]}" && pwd)"
shift
for argument in "$@"; do
    if [[ "$argument" == "Release" || "$argument" == "archive" ]]; then
        echo "Local core overrides are only for development builds" >&2
        exit 1
    fi
done
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
local_dir="$repo_dir/build/usdt-local"
mkdir -p "$local_dir/BitkitUsdt.xcworkspace"
ln -sfn "$core_dir" "$local_dir/bitkit-core"
python3 - "$local_dir" "$repo_dir" <<'PY'
from pathlib import Path
import json
from xml.sax.saxutils import quoteattr
import sys
local, repo = map(Path, sys.argv[1:])
resolved = local/'BitkitUsdt.xcworkspace/xcshareddata/swiftpm'
resolved.mkdir(parents=True, exist_ok=True)
lock = json.loads((repo/'Bitkit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
lock['pins'] = [pin for pin in lock['pins'] if pin['identity'] != 'bitkit-core']
(resolved/'Package.resolved').write_text(json.dumps(lock, indent=2) + '\n')
(local/'BitkitUsdt.xcworkspace/contents.xcworkspacedata').write_text(
    '<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0">'
    + '<FileRef location=' + quoteattr('absolute:'+str(repo/'Bitkit.xcodeproj')) + '/>'
    + '<FileRef location=' + quoteattr('absolute:'+str(local/'bitkit-core')) + '/></Workspace>')
PY
BITKIT_CORE_LOCAL=1 xcodebuild -workspace "$local_dir/BitkitUsdt.xcworkspace" -scheme Bitkit "$@"
