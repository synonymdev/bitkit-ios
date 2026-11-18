#!/usr/bin/env bash
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
case ${1:-} in
  connect|barrier|stop) exec python3 "$scripts/hosted-e2e-pair.py" "$1" ;;
  *) echo 'Usage: hosted-e2e-mac.sh {connect|barrier|stop}' >&2; exit 2 ;;
esac
