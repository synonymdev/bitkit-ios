## How to build

1. Open Bitkit.xcodeproj in XCode
2. Build

## Localization

Localization files are synced from the React Native project. The sync script (`scripts/sync-translations.js`) pulls JSON files from the main repository for multiple languages and sections (onboarding, wallet, common, settings, etc.).

To update translations:

```bash
node scripts/sync-translations.js
```

Files are stored in `Bitkit/Resources/Localization/<lang_code>/<lang_code>_<section>.json`

You can validate the translations using:

```bash
node scripts/validate-translations.js
```

This checks for missing translations and validates that all translation keys used in the Swift code exist in the JSON files. (This check is also automated in GitHub Actions)
