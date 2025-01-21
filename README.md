## How to build

1. Open Bitkit.xcodeproj in XCode
2. Build

## Localization

Localization files are synced from Transifex. Run below command to pull the latest translations:

```bash
tx pull --mode translator -f -a
```

Files are stored in `Bitkit/Resources/Localization/<lang_code>/<lang_code>_<section>.json`

You can validate the translations using:

```bash
node scripts/validate-translations.js
```

This checks for missing translations and validates that all translation keys used in the Swift code exist in the JSON files. (This check is also automated in GitHub Actions)

## Development

### Xcode Previews

Due to the Rust dependencies in the project, Xcode previews are only compatible with iOS 17 and below.
