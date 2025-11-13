#!/bin/bash

# Script to pull translations from Transifex and clean up empty files/directories
#
# Note: Uses --mode onlytranslated to only download translated strings, which may result
# in empty files for incomplete translations that will be cleaned up by this script.

set -e

# Validate script is run from project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCALIZATION_DIR="$PROJECT_ROOT/Bitkit/Resources/Localization"

if [ ! -d "$LOCALIZATION_DIR" ]; then
    echo "Error: Localization directory not found: $LOCALIZATION_DIR"
    echo "Please run this script from the project root directory."
    exit 1
fi

if [ ! -f "$PROJECT_ROOT/.tx/config" ]; then
    echo "Error: Transifex config not found: $PROJECT_ROOT/.tx/config"
    echo "Please ensure Transifex is configured for this project."
    exit 1
fi

# Helper function to rename or merge directories
rename_or_merge() {
    local src="$1"
    local dst="$2"
    local src_name=$(basename "$src")
    local dst_name=$(basename "$dst")
    local merge_errors=0
    
    if [ ! -d "$src" ]; then
        echo "  Warning: Source directory does not exist: $src_name"
        return 1
    fi
    
    if [ ! -d "$dst" ]; then
        echo "  Renaming: $src_name -> $dst_name"
        if mv "$src" "$dst"; then
            return 0
        else
            echo "  Error: Failed to rename $src_name to $dst_name"
            return 1
        fi
    else
        echo "  Merging: $src_name -> $dst_name"
        while IFS= read -r -d '' item; do
            if ! mv "$item" "$dst/" 2>/dev/null; then
                echo "  Warning: Failed to move $(basename "$item") from $src_name"
                merge_errors=$((merge_errors + 1))
            fi
        done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
        
        if [ "$merge_errors" -eq 0 ]; then
            if rmdir "$src" 2>/dev/null; then
                return 0
            else
                echo "  Warning: Could not remove empty directory: $src_name"
                return 1
            fi
        else
            echo "  Error: Some files could not be merged from $src_name"
            return 1
        fi
    fi
}

# Validate .strings file has basic structure
validate_strings_file() {
    local file="$1"
    # Basic validation: check file exists and is readable
    if [ ! -r "$file" ]; then
        echo "  Warning: $file is not readable, skipping normalization"
        return 1
    fi
    # Check if file has at least one translation entry (basic format check)
    if ! grep -q '^"[^"]*"[[:space:]]*=' "$file" 2>/dev/null && [ -s "$file" ]; then
        echo "  Warning: $file does not appear to be a valid .strings file, skipping normalization"
        return 1
    fi
    return 0
}

echo "Pulling translations from Transifex..."

# Check if tx command is available
if ! command -v tx &> /dev/null; then
    echo "Error: Transifex CLI (tx) is not installed or not in PATH"
    echo "Please install it: https://developers.transifex.com/docs/cli"
    exit 1
fi

# Run tx pull and check for errors
set +e
tx pull -a --mode onlytranslated
TX_EXIT_CODE=$?
set -e

if [ "$TX_EXIT_CODE" -ne 0 ]; then
    echo "Error: Transifex pull failed with exit code $TX_EXIT_CODE"
    echo "Please check your Transifex configuration and authentication."
    exit 1
fi

echo ""
echo "Renaming and cleaning up directories..."

RENAMED_COUNT=0

# Process all .lproj directories
while IFS= read -r dir; do
    dir_name=$(basename "$dir")
    dir_path=$(dirname "$dir")
    
    case "$dir_name" in
        arb.lproj)
            rename_or_merge "$dir" "$dir_path/ar.lproj" && RENAMED_COUNT=$((RENAMED_COUNT + 1))
            ;;
        es_419.lproj)
            rename_or_merge "$dir" "$dir_path/es-419.lproj" && RENAMED_COUNT=$((RENAMED_COUNT + 1))
            ;;
        es_ES.lproj)
            rename_or_merge "$dir" "$dir_path/es.lproj" && RENAMED_COUNT=$((RENAMED_COUNT + 1))
            ;;
        pt_PT.lproj|pt-PT.lproj)
            rename_or_merge "$dir" "$dir_path/pt.lproj" && RENAMED_COUNT=$((RENAMED_COUNT + 1))
            ;;
        pt_BR.lproj)
            rename_or_merge "$dir" "$dir_path/pt-BR.lproj" && RENAMED_COUNT=$((RENAMED_COUNT + 1))
            ;;
        *_*.lproj)
            new_name=$(echo "$dir_name" | sed 's/_/-/g')
            [ "$new_name" != "$dir_name" ] && rename_or_merge "$dir" "$dir_path/$new_name" && RENAMED_COUNT=$((RENAMED_COUNT + 1))
            ;;
    esac
done < <(find "$LOCALIZATION_DIR" -type d -name "*.lproj" 2>/dev/null | sort)

echo "  Renamed $RENAMED_COUNT directories"

echo ""
echo "Normalizing .strings files..."

# Normalize .strings files
NORMALIZED_COUNT=0
while IFS= read -r file; do
    if ! validate_strings_file "$file"; then
        continue
    fi
    
    if awk '{
        gsub(/[[:space:]]+$/, "")
        if ($0 ~ /^"[^"]*"[[:space:]]*=[[:space:]]*"";[[:space:]]*$/) next
        print
    }' "$file" > "$file.tmp"; then
        if mv "$file.tmp" "$file" 2>/dev/null; then
            NORMALIZED_COUNT=$((NORMALIZED_COUNT + 1))
        else
            echo "  Warning: Failed to replace $file"
            rm -f "$file.tmp"
        fi
    else
        echo "  Warning: Failed to normalize $file"
        rm -f "$file.tmp"
    fi
done < <(find "$LOCALIZATION_DIR" -type f -name "*.strings" 2>/dev/null)

echo "  Normalized $NORMALIZED_COUNT files"

echo ""
echo "Cleaning up empty files and directories..."

EMPTY_COUNT=0
DELETED_DIRS=0
declare -a dirs_to_check

# Delete empty .strings files
set +e
while IFS= read -r file; do
    line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ' || echo "0")
    translation_count=$(grep -c '^"[^"]*" = ' "$file" 2>/dev/null || echo "0")
    
    if [ "$line_count" -le 2 ] || [ "$translation_count" -eq 0 ]; then
        echo "  Deleting empty file: $file"
        dirs_to_check+=("$(dirname "$file")")
        rm -f "$file"
        EMPTY_COUNT=$((EMPTY_COUNT + 1))
    fi
done < <(find "$LOCALIZATION_DIR" -type f -name "*.strings" 2>/dev/null)
set -e

# Remove empty .lproj directories
for dir in $(printf '%s\n' "${dirs_to_check[@]}" | sort -u | sort -r); do
    [ -d "$dir" ] || continue
    set +e
    file_count=$(find "$dir" -type f ! -name '.DS_Store' 2>/dev/null | wc -l | tr -d ' ')
    set -e
    if [ "$file_count" -eq 0 ]; then
        echo "  Deleting empty directory: $dir"
        if rmdir "$dir" 2>/dev/null; then
            DELETED_DIRS=$((DELETED_DIRS + 1))
        fi
    fi
done

echo ""
echo "Complete!"
echo "  Renamed: $RENAMED_COUNT"
echo "  Normalized: $NORMALIZED_COUNT"
echo "  Deleted files: $EMPTY_COUNT, Deleted dirs: $DELETED_DIRS"
