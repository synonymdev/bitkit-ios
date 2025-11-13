# Bitkit iOS (Native)

> [!CAUTION]
> ⚠️This is **NOT** the repository of the live Bitkit app in the app stores!
> ⚠️Work-in-progress
> The live Bitkit app repository is here: **[github.com/synonymdev/bitkit](https://github.com/synonymdev/bitkit)**

---

## About

This repository contains a **new native iOS app** which is **not ready for production**.


## How to build

1. Open Bitkit.xcodeproj in XCode
2. Build

### Building for E2E tests

To produce an E2E build (uses the local Electrum backend), pass the `E2E_BUILD` compilation flag:

```bash
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
