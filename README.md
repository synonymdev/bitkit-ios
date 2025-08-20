# Bitkit iOS (Native)

> [!CAUTION]
> ⚠️This is **NOT** the repository of the Bitkit app from the app stores!
> ⚠️Work-in-progress
> The live Bitkit app repository is here: **[github.com/synonymdev/bitkit](https://github.com/synonymdev/bitkit)**

---

## About

This repository contains a **new native iOS app** which is **not ready for production**.


## How to build

1. Open Bitkit.xcodeproj in XCode
2. Build

## Localization

Localization files are synced from Transifex. Use [bitkit-transifex-sync](https://github.com/synonymdev/bitkit-transifex-sync) to sync the translations.

This checks for missing translations and validates that all translation keys used in the Swift code exist in the .strings files. (This check is also automated in GitHub Actions)

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
