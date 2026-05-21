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
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG E2E_BUILD' \
  -only-testing:BitkitUITests/TrezorBridgeDashboardUITests \
  -parallel-testing-enabled NO
```

The equivalent GitHub Actions entry point is the manual `ai-device-tests` workflow with suite `trezor-emu`.
