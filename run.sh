#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_PATH="$ROOT_DIR/Bitkit.xcodeproj"
WORKSPACE_PATH="$PROJECT_PATH/project.xcworkspace"
SCHEME="${BITKIT_SCHEME:-Bitkit}"
CONFIGURATION="${BITKIT_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${BITKIT_DERIVED_DATA_PATH:-$ROOT_DIR/build}"
APP_NAME="${BITKIT_APP_NAME:-Bitkit.app}"
BUNDLE_ID="${BITKIT_BUNDLE_ID:-to.bitkit}"
BUILD_CLEAN_RETRIES="${BITKIT_BUILD_CLEAN_RETRIES:-1}"
DESTINATION_TIMEOUT="${BITKIT_DESTINATION_TIMEOUT:-45}"
DEVICE_LIST_TIMEOUT="${BITKIT_DEVICE_LIST_TIMEOUT:-15}"
INSTALL_TIMEOUT="${BITKIT_INSTALL_TIMEOUT:-120}"
DEVICE_SELECTOR="${BITKIT_DEVICE:-${1:-}}"
RESOLVE_PACKAGES="${BITKIT_RESOLVE_PACKAGES:-1}"
ALLOW_PROVISIONING_UPDATES="${BITKIT_ALLOW_PROVISIONING_UPDATES:-1}"
FORCE_CLEAN="${BITKIT_CLEAN:-0}"
LAUNCH_AFTER_INSTALL="${BITKIT_LAUNCH:-1}"
ATTACH_LOGS="${BITKIT_ATTACH_LOGS:-1}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bitkit-run.XXXXXX")"
DEVICE_LIST_JSON="$TMP_DIR/devices.json"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to parse the devicectl device list." >&2
  exit 1
fi

if [[ -z "$DERIVED_DATA_PATH" || "$DERIVED_DATA_PATH" == "/" ]]; then
  echo "error: unsafe derived data path: $DERIVED_DATA_PATH" >&2
  exit 1
fi

bool_enabled() {
  case "${1,,}" in
    1 | true | yes | y | on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_logged() {
  local log_path="$1"
  shift

  set +e
  "$@" 2>&1 | tee "$log_path"
  local status="${PIPESTATUS[0]}"
  set -e

  return "$status"
}

clean_build_folder() {
  echo "Cleaning Xcode build products and intermediates in $DERIVED_DATA_PATH..."
  rm -rf \
    "$DERIVED_DATA_PATH/Build" \
    "$DERIVED_DATA_PATH/Index.noindex" \
    "$DERIVED_DATA_PATH/ModuleCache.noindex" \
    "$DERIVED_DATA_PATH/CompilationCache.noindex" \
    "$DERIVED_DATA_PATH/SDKStatCaches.noindex" \
    "$DERIVED_DATA_PATH/Logs/Build"
}

resolve_packages() {
  if ! bool_enabled "$RESOLVE_PACKAGES"; then
    echo "Skipping Swift package resolution because BITKIT_RESOLVE_PACKAGES=$RESOLVE_PACKAGES."
    return
  fi

  echo "Resolving Swift packages..."
  mkdir -p "$DERIVED_DATA_PATH/SourcePackages"

  run_logged "$TMP_DIR/package-resolve.log" \
    xcodebuild \
    -resolvePackageDependencies \
    -workspace "$WORKSPACE_PATH" \
    -scheme "$SCHEME" \
    -clonedSourcePackagesDirPath "$DERIVED_DATA_PATH/SourcePackages"
}

build_app() {
  local xcodebuild_args=(
    -workspace "$WORKSPACE_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "platform=iOS,id=$XCODE_DEVICE_ID"
    -destination-timeout "$DESTINATION_TIMEOUT"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -clonedSourcePackagesDirPath "$DERIVED_DATA_PATH/SourcePackages"
  )

  if bool_enabled "$ALLOW_PROVISIONING_UPDATES"; then
    xcodebuild_args+=(
      -allowProvisioningUpdates
      -allowProvisioningDeviceRegistration
    )
  fi

  if bool_enabled "$FORCE_CLEAN"; then
    clean_build_folder
  fi

  local max_attempts=$((BUILD_CLEAN_RETRIES + 1))
  local attempt=1

  while ((attempt <= max_attempts)); do
    if ((attempt == 1)); then
      echo "Building $SCHEME $CONFIGURATION app..."
    else
      echo "Retrying build after clean ($attempt/$max_attempts)..."
    fi

    if run_logged "$TMP_DIR/build-attempt-$attempt.log" xcodebuild "${xcodebuild_args[@]}" build; then
      return 0
    fi

    if ((attempt == max_attempts)); then
      echo "Build failed after $max_attempts attempt(s)." >&2
      return 1
    fi

    echo "Build failed. Running the Clean Build Folder equivalent and trying again..." >&2
    clean_build_folder
    ((attempt += 1))
  done
}

find_app_path() {
  local expected_path="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION-iphoneos/$APP_NAME"
  local products_dir="$DERIVED_DATA_PATH/Build/Products"
  local found_path

  if [[ -d "$expected_path" ]]; then
    printf '%s\n' "$expected_path"
    return 0
  fi

  if [[ -d "$products_dir" ]]; then
    found_path="$(find "$products_dir" -type d -name "$APP_NAME" -print -quit)"
    if [[ -n "$found_path" ]]; then
      printf '%s\n' "$found_path"
      return 0
    fi
  fi

  echo "error: app bundle not found under $products_dir" >&2
  return 1
}

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

install_app() {
  local attempt=1
  local max_attempts=2

  while ((attempt <= max_attempts)); do
    echo "Installing $APP_PATH..."

    if run_logged "$TMP_DIR/install-attempt-$attempt.log" \
      xcrun devicectl device install app \
      --device "$DEVICE_ID" \
      --timeout "$INSTALL_TIMEOUT" \
      "$APP_PATH"; then
      return 0
    fi

    if ((attempt == max_attempts)); then
      echo "Install failed after $max_attempts attempt(s)." >&2
      echo "The script did not uninstall $BUNDLE_ID automatically, to avoid erasing local app data." >&2
      return 1
    fi

    echo "Install failed. Waiting briefly and retrying once..." >&2
    sleep 2
    ((attempt += 1))
  done
}

launch_app() {
  local attempt=1
  local max_attempts=2
  local launch_log
  local launch_args

  while ((attempt <= max_attempts)); do
    launch_log="$TMP_DIR/launch-attempt-$attempt.log"
    echo "Launching $BUNDLE_ID..."
    launch_args=(
      xcrun devicectl device process launch
      --device "$DEVICE_ID"
      "$BUNDLE_ID"
      --terminate-existing
    )

    if bool_enabled "$ATTACH_LOGS"; then
      launch_args+=(--console)
    fi

    if run_logged "$launch_log" "${launch_args[@]}"; then
      if ! bool_enabled "$ATTACH_LOGS"; then
        echo "Launched $BUNDLE_ID."
      fi
      return 0
    fi

    if grep -qiE "BSErrorCodeDescription = Locked|device was not, or could not be, unlocked|Unable to launch .* because .* unlocked" "$launch_log"; then
      echo "Installed successfully, but launch failed because $DEVICE_NAME is locked." >&2
      echo "Unlock the iPhone and rerun ./run.sh, or launch Bitkit manually." >&2
      return 1
    fi

    if ((attempt == max_attempts)); then
      echo "Launch failed after $max_attempts attempt(s)." >&2
      return 1
    fi

    echo "Launch failed. Waiting briefly and retrying once..." >&2
    sleep 2
    ((attempt += 1))
  done
}

echo "Looking for connected iPhones..."
xcrun devicectl list devices \
  --filter "hardwareProperties.deviceType == 'iPhone' AND hardwareProperties.reality == 'physical'" \
  --timeout "$DEVICE_LIST_TIMEOUT" \
  --json-output "$DEVICE_LIST_JSON" >/dev/null

if ! DEVICE_INFO="$(
  python3 - "$DEVICE_LIST_JSON" "$DEVICE_SELECTOR" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as file:
    payload = json.load(file)

selector = sys.argv[2].strip().casefold()
devices = payload.get("result", {}).get("devices", [])
eligible_devices = []

for device in devices:
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    identifier = device.get("identifier")
    udid = hardware.get("udid")
    name = properties.get("name", "Unknown iPhone")

    if hardware.get("deviceType") != "iPhone" or hardware.get("reality") != "physical" or not identifier:
        continue

    searchable = [identifier, udid or "", name]
    if selector and not any(selector in value.casefold() for value in searchable):
        continue

    score = (
        connection.get("tunnelState") == "connected",
        connection.get("pairingState") == "paired",
        connection.get("lastConnectionDate") or "",
    )
    eligible_devices.append((score, identifier, udid or identifier, name))

if not eligible_devices:
    raise SystemExit(1)

eligible_devices.sort(reverse=True)
_, identifier, udid, name = eligible_devices[0]
print(f"{identifier}\t{udid or identifier}\t{name}")
PY
)"; then
  if [[ -n "$DEVICE_SELECTOR" ]]; then
    echo "No connected physical iPhone matched '$DEVICE_SELECTOR'." >&2
  else
    echo "No connected physical iPhone found." >&2
  fi
  exit 1
fi

DEVICE_ID="${DEVICE_INFO%%$'\t'*}"
REMAINING_DEVICE_INFO="${DEVICE_INFO#*$'\t'}"
XCODE_DEVICE_ID="${REMAINING_DEVICE_INFO%%$'\t'*}"
DEVICE_NAME="${REMAINING_DEVICE_INFO#*$'\t'}"

echo "Using $DEVICE_NAME ($DEVICE_ID)"

resolve_packages
build_app

APP_PATH="$(find_app_path)"

echo "Removing static framework stubs..."
remove_static_framework_stubs "$APP_PATH"

install_app

if bool_enabled "$LAUNCH_AFTER_INSTALL"; then
  launch_app
else
  echo "Skipping launch because BITKIT_LAUNCH=$LAUNCH_AFTER_INSTALL."
fi
