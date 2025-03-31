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

### Git Hooks

This project uses pre-commit hooks to ensure code quality. To set up the hooks, run:

```bash
chmod +x scripts/setup-hooks.sh
./scripts/setup-hooks.sh
```

This will install the pre-commit hook that runs various checks before each commit, including:
- Running swift-format on staged Swift files

### Xcode Previews

Due to the Rust dependencies in the project, Xcode previews are only compatible with iOS 17 and below.
