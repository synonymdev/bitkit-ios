# Bitkit iOS (Native)

## About

This repository contains the **native iOS app** for Bitkit.

## How to build

1. Open Bitkit.xcodeproj in XCode
2. Build

### Network Configuration

The app automatically selects the network based on the build configuration:

- **Debug builds** → Uses **Regtest** network (for local development and testing)
- **Release builds** → Uses **Bitcoin Mainnet** network (for production)

### Building for E2E tests

To produce an E2E build (uses the local Electrum backend by default), pass the `E2E_BUILD` compilation flag:

```bash
xcodebuild -workspace Bitkit.xcodeproj/project.xcworkspace \
  -scheme Bitkit \
  -configuration Debug \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) E2E_BUILD' \
  build
```

You can also set the backend/network at build time via Info.plist substitutions:

```bash
# Use network Electrum with regtest
E2E_BACKEND=network E2E_NETWORK=regtest \
  xcodebuild -workspace Bitkit.xcodeproj/project.xcworkspace \
  -scheme Bitkit \
  -configuration Debug \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) E2E_BUILD' \
  build

# Use network Electrum with mainnet
E2E_BACKEND=network E2E_NETWORK=bitcoin \
  xcodebuild -workspace Bitkit.xcodeproj/project.xcworkspace \
  -scheme Bitkit \
  -configuration Debug \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) E2E_BUILD' \
  build
```

## Localization

### Pulling Translations

To pull the latest translations from Transifex:

1. **Install Transifex CLI** (if not already installed):
   - Follow the installation instructions: [Transifex CLI Installation](https://developers.transifex.com/docs/cli)

2. **Authenticate with Transifex** (if not already configured):
   - Create a `.transifexrc` file in your home directory (`~/.transifexrc`) with your API token:
     ```ini
     [https://www.transifex.com]
     rest_hostname = https://rest.api.transifex.com
     token         = YOUR_API_TOKEN_HERE
     ```
   - You can get your API token from your [Transifex account settings](https://www.transifex.com/user/settings/api/)
   - The CLI will prompt you for an API token if one is not configured

3. **Pull translations**:
   ```sh
   ./scripts/pull-translations.sh
   ```

### Validating Translations

This checks for missing translations and validates that all translation keys used in the Swift code exist in the `.strings` files. (This check is also automated in GitHub Actions)

```bash
node scripts/validate-translations.js
```

## Development

### Formatting

This project uses [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) for code formatting. Configuration is in `.swiftformat`.

**Install SwiftFormat:**
```bash
brew install swiftformat
```

**IDE Extensions:**
- [VSCode extension](https://open-vsx.org/extension/vknabel/vscode-swiftformat)
- [Xcode extension](https://github.com/nicklockwood/SwiftFormat#xcode-source-editor-extension)

**Format code:**
```bash
swiftformat .
```

### Git Hooks

The project includes git hooks to automatically check code formatting before commits.

**Set up git hooks:**
1. Install [git-format-staged](https://github.com/hallettj/git-format-staged): `npm install -g git-format-staged`
2. Run: `./scripts/setup-hooks.sh`

This installs a pre-commit hook that lints Swift files with SwiftFormat.

### Xcode Previews

Due to the Rust dependencies in the project, Xcode previews are only compatible with iOS 17 and below.

### Common Tasks

Day-to-day commands live in the `Justfile`:

```bash
# Build, install and launch on a connected device (wraps ./run.sh)
just run [release] [logs]

# Clear caches, cheapest first
just clean [build|derived-data|modules|spm|all]...
```

## Troubleshooting

### After bumping a Rust/UniFFI dependency

`bitkit-core`, `ldk-node`, `paykit` and `vss-rust-client-ffi` ship UniFFI-generated headers whose size changes on almost every version. Xcode keys its explicit precompiled modules (`.pcm`) on the header's size and mtime, and in explicit-modules mode a stale `.pcm` is a hard error — nothing is allowed to rebuild it mid-compile. The build fails with:

```
error: file '.../include/bitkitcoreFFI.h' has been modified since the module file '.../bitkitcoreFFI-<hash>.pcm' was built
note: size changed from expected 121271 to 128544
```

followed by a cascade of misleading `cannot find 'uniffi_bitkitcore_checksum_func_*' in scope` errors in `bitkitcore.swift`. The root-cause line is easy to miss — it is emitted as `<unknown>:0:` and sorts away from the rest. Clear the module caches and rebuild:

```bash
just clean modules
```

Xcode's **File ▸ Packages ▸ Reset Package Caches** does *not* clear these. Note that `vss-rust-client-ffi` tracks `master`, so this can bite after a plain re-resolve with no version change in the diff.

### `cannot find checksum func` with no "has been modified" error

Same message, different cause: the downloaded binary artifact genuinely lacks the symbol, because a re-cut tag reuses a URL that SPM has already cached. Check which one you have before reaching for the heavier fix:

```bash
grep -c uniffi_bitkitcore_checksum_func_<name> \
  ~/Library/Developer/Xcode/DerivedData/Bitkit-*/SourcePackages/artifacts/bitkit-core/BitkitCoreFFI/BitkitCore.xcframework/ios-arm64-simulator/Headers/bitkitcoreFFI.h
```

Non-zero → module cache problem, `just clean modules` is enough. Zero → the artifact really is stale:

```bash
just clean spm
xcodebuild -resolvePackageDependencies -project Bitkit.xcodeproj -scheme Bitkit
```

The first CLI resolve often dies with `fatalError` or `file not found at path: .../<Name>.xcframework.zip` while fetching the large binary artifacts. Run it again — it can take two or three attempts.

### `There is no XCFramework found at ...`

An aborted resolve can leave an artifact half-extracted, with only a `__MACOSX` directory where the `.xcframework` should be. Re-running `-resolvePackageDependencies` reports success without repairing it, because SPM's workspace state still claims the artifact is present. Use `just clean spm` and re-resolve.

### Why we don't disable explicit modules

`SWIFT_ENABLE_EXPLICIT_MODULES` is deliberately left at Xcode's default (`YES`). Setting it to `NO` would make the stale-`.pcm` error above disappear, but it slows every clean build — including CI, which never caches DerivedData — and trades a loud error for silently stale modules. For a one-off local build you can still override it:

```bash
xcodebuild ... SWIFT_ENABLE_EXPLICIT_MODULES=NO
```

## Contributing

### AI Code Review with Claude

This repository has Claude Code integrated for on-demand AI assistance on issues and pull requests.

#### How to Use

Mention `@claude` in any PR comment, issue, or review to trigger Claude:

| Command | Description |
|---------|-------------|
| `@claude review` | Request a code review of the PR |
| `@claude /review` | Same as above (slash command) |
| `@claude review focus on security` | Review with specific focus |
| `@claude explain this change` | Ask questions about the code |
| `@claude fix the null pointer issue` | Request Claude to implement a fix |
| `@claude /help` | Show available commands |

#### Notes

- Claude follows the project guidelines defined in `CLAUDE.md`
- **Automatic reviews** run on every PR open and push (updates same comment)
- **On-demand assistance** via `@claude` mentions in comments/issues
- Claude can read CI results to provide context-aware feedback
- For implementation requests, Claude will create commits on your branch

#### Example

```
@claude review

Please focus on:
- SwiftUI idioms and best practices
- @Observable patterns and memory management (retain cycles)
- Thread safety with async/await and actors
```

## License

This project is licensed under the MIT License.
See the [LICENSE](./LICENSE) file for more details.
