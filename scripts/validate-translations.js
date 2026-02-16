const fs = require('fs');
const path = require('path');
const glob = require('glob');

// Collection of all errors and warnings
const errors = [];
const warningMap = new Map(); // key -> Set of languages
const usedKeys = new Set(); // keys referenced in Swift (t, NSLocalizedString, tPlural, localizedRandom)
// Dynamic key patterns: keys built with string interpolation, e.g. t("widgets__\(type.rawValue)__name") -> { prefix: "widgets__", suffix: "__name" }
const dynamicKeyPatterns = [];

// Key pattern: alphanumeric and underscores (e.g. wallet__send_to, common__continue)
const KEY_PATTERN = '[a-zA-Z0-9_]+';

/** Returns true if key is considered used (literal or matches a dynamic pattern). */
function isKeyUsed(key) {
    if (usedKeys.has(key)) return true;
    return dynamicKeyPatterns.some(({ prefix, suffix }) => key.startsWith(prefix) && key.endsWith(suffix) && key.length > prefix.length + suffix.length);
}

/** Collect all localization keys referenced in Swift (literal and dynamic patterns). */
function collectUsedKeys(swiftFiles) {
    const keyRegex = new RegExp(
        `(?:\\bt\\(|NSLocalizedString\\(|tPlural\\(|localizedRandom\\()\\s*['"](${KEY_PATTERN})['"]`,
        'g'
    );
    // Dynamic key: t("prefix\(expr)suffix") – one interpolation
    const dynamicRegex = /(?:t|tPlural|localizedRandom)\s*\(\s*"([^"\\]*)\\[^)]*\)([^"]*)"/g;
    swiftFiles.forEach(filePath => {
        const fullPath = path.join(__dirname, filePath);
        const content = fs.readFileSync(fullPath, 'utf8');
        let match;
        while ((match = keyRegex.exec(content)) !== null) {
            usedKeys.add(match[1]);
        }
        while ((match = dynamicRegex.exec(content)) !== null) {
            const prefix = match[1];
            const suffix = match[2];
            if (prefix.length > 0 || suffix.length > 0) {
                const existing = dynamicKeyPatterns.find(p => p.prefix === prefix && p.suffix === suffix);
                if (!existing) dynamicKeyPatterns.push({ prefix, suffix });
            }
        }
    });
}

/** Return set of keys defined in en.lproj/Localizable.strings. */
function getKeysFromStringsFile() {
    const stringsPath = path.join(__dirname, '..', 'Bitkit', 'Resources', 'Localization', 'en.lproj', 'Localizable.strings');
    const content = fs.readFileSync(stringsPath, 'utf8');
    const keys = new Set();
    const keyLineRegex = /^\s*"([^"]+)"\s*=/;
    content.split('\n').forEach(line => {
        const m = line.match(keyLineRegex);
        if (m) keys.add(m[1]);
    });
    return keys;
}

function validateKeyInStrings(key, relativePath, lineNumber) {
    const stringsPath = path.join(__dirname, '..', 'Bitkit', 'Resources', 'Localization', 'en.lproj', 'Localizable.strings');
    try {
        const stringsContent = fs.readFileSync(stringsPath, 'utf8');
        if (!stringsContent.includes(`"${key}" =`)) {
            errors.push(`Error: Missing required English translation for key '${key}' in Localizable.strings (${relativePath}:${lineNumber})`);
            return false;
        }
        // Check other languages (warnings)
        const localizationPath = path.join(__dirname, '..', 'Bitkit', 'Resources', 'Localization');
        const languages = fs.readdirSync(localizationPath)
            .filter(dir => dir.endsWith('.lproj') && dir !== 'en.lproj')
            .map(dir => dir.replace('.lproj', ''));

        languages.forEach(lang => {
            const langStringsPath = path.join(localizationPath, `${lang}.lproj`, 'Localizable.strings');
            try {
                const langStringsContent = fs.readFileSync(langStringsPath, 'utf8');
                if (!langStringsContent.includes(`"${key}" =`)) {
                    const warningKey = `${key}:${relativePath}:${lineNumber}`;
                    if (!warningMap.has(warningKey)) {
                        warningMap.set(warningKey, new Set());
                    }
                    warningMap.get(warningKey).add(lang);
                }
            } catch (error) {
                const warningKey = `${key}:${relativePath}:${lineNumber}`;
                if (!warningMap.has(warningKey)) {
                    warningMap.set(warningKey, new Set());
                }
                warningMap.get(warningKey).add(lang);
            }
        });
        return true;
    } catch (error) {
        errors.push(`Error: Could not read Localizable.strings file: ${error.message}`);
        return false;
    }
}

// Function to process a Swift file
function processSwiftFile(filePath) {
    let hasErrors = false;
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n');

    // Skip files without any translation calls (NSLocalizedString or t())
    const hasTranslations = content.includes('NSLocalizedString(') || content.includes('t(');
    if (!hasTranslations) {
        return true;
    }

    // Skip the helper file that defines t()
    const relativePath = path.relative(path.join(__dirname, '..'), filePath);
    if (relativePath.includes('LocalizeHelpers.swift')) {
        return true;
    }

    lines.forEach((line, index) => {
        const lineNumber = index + 1;

        // 1) NSLocalizedString("key") – validate key exists
        const nsLocalizedMatches = line.match(new RegExp(`NSLocalizedString\\(['"](${KEY_PATTERN})['"]`, 'g'));
        if (nsLocalizedMatches) {
            nsLocalizedMatches.forEach(match => {
                const keyMatch = match.match(new RegExp(`['"](${KEY_PATTERN})['"]`));
                if (keyMatch) {
                    usedKeys.add(keyMatch[1]);
                    if (!validateKeyInStrings(keyMatch[1], relativePath, lineNumber)) hasErrors = true;
                }
            });
        }

        // 2) t("key") or t('key') – validate key exists; t() must receive a localization key
        const tLiteralMatches = line.match(new RegExp(`\\bt\\(\\s*['"](${KEY_PATTERN})['"]`, 'g'));
        if (tLiteralMatches) {
            tLiteralMatches.forEach(match => {
                const keyMatch = match.match(new RegExp(`['"](${KEY_PATTERN})['"]`));
                if (keyMatch) {
                    usedKeys.add(keyMatch[1]);
                    if (!validateKeyInStrings(keyMatch[1], relativePath, lineNumber)) hasErrors = true;
                }
            });
        }

        // 3) t() called with no key at all – error (t() with no arguments)
        if (line.match(/\bt\s*\(\s*\)/)) {
            errors.push(`Error: t() must be called with a localization key (${relativePath}:${lineNumber})`);
            hasErrors = true;
        }
    });

    return !hasErrors;
}

// Function to display validation results
function displayResults(showWarnings = false, showUnused = false) {
    // Sort errors by file path and line number
    const sortByLocation = (a, b) => {
        const aMatch = a.match(/\((.*?):(\d+)\)/);
        const bMatch = b.match(/\((.*?):(\d+)\)/);
        if (!aMatch || !bMatch) return 0;

        const [, aPath, aLine] = aMatch;
        const [, bPath, bLine] = bMatch;

        if (aPath !== bPath) {
            return aPath.localeCompare(bPath);
        }
        return parseInt(aLine) - parseInt(bLine);
    };

    // Display errors first
    if (errors.length > 0) {
        console.error('\nErrors:');
        errors.sort(sortByLocation).forEach(error => console.error(error));
    }

    // Display warnings only when --warnings / -w flag is set
    if (showWarnings && warningMap.size > 0) {
        console.log('\nWarnings:');
        const sortedWarnings = Array.from(warningMap.entries()).sort((a, b) => {
            const [aKey] = a;
            const [bKey] = b;
            const [, aPath, aLine] = aKey.split(':');
            const [, bPath, bLine] = bKey.split(':');

            if (aPath !== bPath) {
                return aPath.localeCompare(bPath);
            }
            return parseInt(aLine) - parseInt(bLine);
        });

        for (const [warningKey, missingLangs] of sortedWarnings) {
            const [key, filePath, lineNumber] = warningKey.split(':');
            const langList = Array.from(missingLangs).sort().join(', ');
            console.warn(`Warning: Missing translation for key '${key}' in languages: ${langList} (${filePath}:${lineNumber})`);
        }
    }

    // Display unused keys when --unused / -u flag is set
    if (showUnused) {
        const allKeys = getKeysFromStringsFile();
        const unused = [...allKeys].filter(k => !isKeyUsed(k)).sort();
        if (unused.length > 0) {
            console.error(`\nUnused localization keys (${unused.length}):`);
            unused.forEach(key => console.error(`  ${key}`));
        } else {
            console.error('\nNo unused localization keys.');
        }
    }

    // Display summary (stderr so it appears after errors when both go to stderr)
    let summary = `\nValidation summary: ${errors.length} errors`;
    if (showWarnings) summary += `, ${warningMap.size} warnings`;
    else if (warningMap.size > 0) summary += ` (${warningMap.size} warnings hidden; use --warnings to show)`;
    if (showUnused) {
        const allKeys = getKeysFromStringsFile();
        const unusedCount = [...allKeys].filter(k => !isKeyUsed(k)).length;
        summary += `, ${unusedCount} unused keys`;
    }
    summary += '.';
    console.error(summary);
}

// Main function
function main() {
    const showWarnings = process.argv.includes('--warnings') || process.argv.includes('-w');
    const showUnused = process.argv.includes('--unused') || process.argv.includes('-u');
    console.log('Validating translations...');

    // Find all Swift files - search from parent directory
    const swiftFiles = glob.sync('../Bitkit/**/*.swift', { cwd: __dirname });

    // Collect keys referenced in Swift (for unused-key check)
    collectUsedKeys(swiftFiles);

    // Process each file
    let hasErrors = false;
    swiftFiles.forEach(filePath => {
        try {
            if (!processSwiftFile(path.join(__dirname, filePath))) {
                hasErrors = true;
            }
        } catch (error) {
            const relativePath = path.relative(path.join(__dirname, '..'), filePath);
            console.error(`Error processing file ${relativePath}:`, error);
            errors.push(`Error: Failed to process file ${relativePath}: ${error.message}`);
            hasErrors = true;
        }
    });

    // Display results
    displayResults(showWarnings, showUnused);

    if (hasErrors) {
        console.error('\nValidation failed! See errors above.');
        process.exit(1);
    } else {
        console.log('\nValidation successful! All translations are properly configured.');
        process.exit(0);
    }
}

main(); 