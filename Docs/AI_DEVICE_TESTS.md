# AI Device Tests

These tests are for developer-triggered AI device validation only. They are not part of default CI.

## Trezor Emulator

Start the emulator stack from a sibling `bitkit-docker` checkout on `main`:

```bash
cd /path/to/bitkit-docker
docker compose up -d
./scripts/trezor-emulator start
```

Run the iOS suite from this repository:

```bash
TEST_TREZOR_EMU=1 \
TEST_TREZOR_RESET_STATE=1 \
TREZOR_BRIDGE=true \
TREZOR_BRIDGE_URL=http://127.0.0.1:21325 \
TREZOR_ELECTRUM_URL=tcp://127.0.0.1:60001 \
E2E=true E2E_BACKEND=local E2E_NETWORK=regtest GEO=false \
xcodebuild test \
  -workspace Bitkit.xcodeproj/project.xcworkspace \
  -scheme BitkitAITests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -derivedDataPath DerivedData \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG E2E_BUILD TEST_TREZOR_EMU' \
  -only-testing:BitkitUITests/TrezorBridgeDashboardUITests \
  -parallel-testing-enabled NO
```

The equivalent GitHub Actions entry point is the manual `ai-device-tests` workflow with suite `trezor-emu`.

## Why Bridge

Current iOS releases do not expose WebUSB-style access for devices like Trezor in Safari/WebKit. The connected-device path on iOS is Bluetooth for Trezor models that support it.

The `bitkit-docker` emulator tooling still stays useful for iOS automation because Trezor User Env exposes the emulator through Trezor Bridge on the Mac. The simulator can use that localhost Bridge endpoint while exercising the same dashboard behavior. If Trezor User Env later exposes a BLE peripheral that CoreBluetooth can scan, this suite should move to that transport without changing the dashboard coverage.
