#!/bin/bash

# Base URLs and directories
GITHUB_RAW_BASE="https://raw.githubusercontent.com/synonymdev/bitkit/master/src/utils/i18n/locales"
LOCAL_DIR="Bitkit/Resources/Localization"

# Array of language codes from the repository
LANGUAGES=(
    "arb" "ca" "cs" "de" "el" "en" "es_419" "es_ES" "fa" "fr" 
    "it" "ja" "ko" "nl" "no" "pl" "pt_BR" "pt_PT" "ro" "ru" "uk" "yo"
)

# Array of section names that need to be downloaded
SECTIONS=(
    "onboarding" "wallet" "common" "settings" "lightning" "cards" "fee"
)

# Create local directories if they don't exist
for lang in "${LANGUAGES[@]}"; do
    mkdir -p "$LOCAL_DIR/$lang"
done

# Download files for each language and section
for lang in "${LANGUAGES[@]}"; do
    echo "Downloading files for language: $lang"
    
    for section in "${SECTIONS[@]}"; do
        url="$GITHUB_RAW_BASE/$lang/$section.json"
        output="$LOCAL_DIR/$lang/${lang}_${section}.json"
        
        echo "Fetching $url"
        if curl -s -f "$url" -o "$output"; then
            echo "✅ Downloaded $section.json for $lang"
        else
            echo "❌ Failed to download $section.json for $lang"
        fi
    done
done

echo "Done! 🎉" 