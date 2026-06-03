#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DERIVED_DATA_PATH="$ROOT_DIR/build"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/Bitkit.app"
BUNDLE_ID="to.bitkit"

DEVICE_LIST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bitkit-devices.XXXXXX")"
DEVICE_LIST_JSON="$DEVICE_LIST_DIR/devices.json"
trap 'rm -rf "$DEVICE_LIST_DIR"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to parse the devicectl device list." >&2
  exit 1
fi

remove_static_framework_stubs() {
  local app_path="$1"
  local frameworks_dir="$app_path/Frameworks"
  local removed_count=0

  if [[ ! -d "$app_path" ]]; then
    echo "error: app bundle not found: $app_path" >&2
    exit 1
  fi

  if [[ ! -d "$frameworks_dir" ]]; then
    echo "No Frameworks directory found in $app_path."
    return
  fi

  shopt -s nullglob

  for framework_path in "$frameworks_dir"/*.framework; do
    local framework_name
    local info_plist
    local executable_name
    local plist_executable
    local executable_path

    framework_name="$(basename "$framework_path" .framework)"
    info_plist="$framework_path/Info.plist"
    executable_name="$framework_name"

    if [[ -f "$info_plist" ]]; then
      plist_executable="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info_plist" 2>/dev/null || true)"
      if [[ -n "$plist_executable" ]]; then
        executable_name="$plist_executable"
      fi
    fi

    executable_path="$framework_path/$executable_name"
    if [[ -e "$executable_path" ]]; then
      continue
    fi

    echo "Removing static framework stub: $(basename "$framework_path") (missing executable: $executable_name)"
    rm -rf "$framework_path"

    if [[ -d "$framework_path" ]]; then
      echo "error: failed to remove static framework stub: $framework_path" >&2
      exit 1
    fi

    ((removed_count += 1))
  done

  if ((removed_count == 0)); then
    echo "No static framework stubs found."
  elif ((removed_count == 1)); then
    echo "Removed 1 static framework stub."
  else
    echo "Removed $removed_count static framework stubs."
  fi
}

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
udid = device.get("hardwareProperties", {}).get("udid")

if not identifier:
    raise SystemExit(1)

print(f"{identifier}\t{udid or identifier}\t{name}")
PY
)"; then
  echo "No connected physical iPhone found." >&2
  exit 1
fi

DEVICE_ID="${DEVICE_INFO%%$'\t'*}"
REMAINING_DEVICE_INFO="${DEVICE_INFO#*$'\t'}"
XCODE_DEVICE_ID="${REMAINING_DEVICE_INFO%%$'\t'*}"
DEVICE_NAME="${REMAINING_DEVICE_INFO#*$'\t'}"

echo "Using $DEVICE_NAME ($DEVICE_ID)"
echo "Building Debug app..."
xcodebuild \
  -project "$ROOT_DIR/Bitkit.xcodeproj" \
  -scheme Bitkit \
  -configuration Debug \
  -destination "platform=iOS,id=$XCODE_DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

echo "Removing static framework stubs..."
remove_static_framework_stubs "$APP_PATH"

echo "Installing $APP_PATH..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "Launching $BUNDLE_ID..."
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" --terminate-existing --console
