## How to build

1. Open Bitkit.xcodeproj in XCode
2. Build

## Localization

Localization files are synced from the React Native project. The sync script (`sync-rn-local.sh`) pulls JSON files from the main repository for multiple languages and sections (onboarding, wallet, common, settings, etc.).

To update translations:

```bash
./sync-rn-local.sh
```

Files are stored in `Bitkit/Resources/Localization/<lang_code>/<lang_code>_<section>.json`
