#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/build"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/Bitkit.app"
BUNDLE_ID="to.bitkit"

DEVICE_LIST_JSON="$(mktemp "${TMPDIR:-/tmp}/bitkit-devices.XXXXXX.json")"
trap 'rm -f "$DEVICE_LIST_JSON"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to parse the devicectl device list." >&2
  exit 1
fi

echo "Looking for connected iPhones..."
xcrun devicectl list devices \
  --filter "hardwareProperties.deviceType == 'iPhone' AND hardwareProperties.reality == 'physical'" \
  --timeout 10 \
  --json-output "$DEVICE_LIST_JSON" >/dev/null

if ! DEVICE_INFO="$(
  python3 - "$DEVICE_LIST_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as file:
    payload = json.load(file)

devices = payload.get("result", {}).get("devices", [])

if not devices:
    raise SystemExit(1)

device = devices[0]
name = device.get("deviceProperties", {}).get("name", "Unknown iPhone")
identifier = device.get("identifier")

if not identifier:
    raise SystemExit(1)

print(f"{identifier}\t{name}")
PY
)"; then
  echo "No connected physical iPhone found." >&2
  exit 1
fi

DEVICE_ID="${DEVICE_INFO%%$'\t'*}"
DEVICE_NAME="${DEVICE_INFO#*$'\t'}"

echo "Using $DEVICE_NAME ($DEVICE_ID)"
echo "Building Debug app..."
xcodebuild \
  -project "$ROOT_DIR/Bitkit.xcodeproj" \
  -scheme Bitkit \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

LDK_STUB_PATH="$APP_PATH/Frameworks/LDKNodeFFI.framework"
if [[ -d "$LDK_STUB_PATH" ]]; then
  echo "Removing LDKNodeFFI static framework stub..."
  rm -rf "$LDK_STUB_PATH"
fi

echo "Installing $APP_PATH..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "Launching $BUNDLE_ID..."
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" --terminate-existing --console
