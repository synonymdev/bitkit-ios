const fs = require('fs');
const path = require('path');
const glob = require('glob');

// Cache for loaded translations
const translationCache = new Map();

// Collection of all errors and warnings
const errors = [];
const warnings = [];

// Function to load translations for a specific language and section
function loadTranslations(langCode, section) {
    const cacheKey = `${langCode}:${section}`;
    if (translationCache.has(cacheKey)) {
        return translationCache.get(cacheKey);
    }

    const filePath = path.join(__dirname, '..', 'Bitkit', 'Resources', 'Localization', langCode, `${langCode}_${section}.json`);
    try {
        const content = fs.readFileSync(filePath, 'utf8');
        const translations = JSON.parse(content);
        translationCache.set(cacheKey, translations);
        return translations;
    } catch (error) {
        if (error.code === 'ENOENT') {
            return null;
        }
        throw error;
    }
}

// Function to get all language directories
function getAllLanguages() {
    const localizationPath = path.join(__dirname, '..', 'Bitkit', 'Resources', 'Localization');
    return fs.readdirSync(localizationPath)
        .filter(item => {
            const itemPath = path.join(localizationPath, item);
            return fs.statSync(itemPath).isDirectory();
        });
}

// Function to validate a translation key
function validateKey(key, section, filePath, lineNumber) {
    let hasErrors = false;
    
    // First check if the key exists in English translations
    const enTranslations = loadTranslations('en', section);
    if (!enTranslations) {
        errors.push(`Error: Missing English translation file for section '${section}' (${filePath}:${lineNumber})`);
        return false;
    }

    if (!enTranslations[key] || !enTranslations[key].string) {
        errors.push(`Error: Missing required English translation for key '${key}' in section '${section}' (${filePath}:${lineNumber})`);
        return false;
    }

    // Then check other languages
    const languages = getAllLanguages().filter(lang => lang !== 'en');
    for (const lang of languages) {
        const translations = loadTranslations(lang, section);
        if (!translations || !translations[key] || !translations[key].string) {
            warnings.push(`Warning: Missing translation for key '${key}' in language '${lang}' section '${section}' (${filePath}:${lineNumber})`);
        }
    }

    return true;
}

// Function to process a Swift file
function processSwiftFile(filePath) {
    let hasErrors = false;
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n');

    // First check if the file uses translations
    const hasTranslations = content.includes('t(') || content.includes('parts(');
    if (!hasTranslations) {
        return true; // Skip files without any translation calls
    }

    // Find the section declaration - default to 'common' if not found
    const sectionMatch = content.match(/useTranslation\(\.([a-zA-Z0-9_]+)\)/);
    const section = sectionMatch ? sectionMatch[1] : 'common';

    // Get relative path for error reporting
    const relativePath = path.relative(path.join(__dirname, '..'), filePath);

    // Find all translation keys
    lines.forEach((line, index) => {
        const lineNumber = index + 1;

        // More precise regex patterns that require t(" or t(' at the start
        const tMatches = line.match(/\bt\(['"]([a-zA-Z0-9_.]+)['"]\)/g);
        const partsMatches = line.match(/\bparts\(['"]([a-zA-Z0-9_.]+)['"]\)/g);

        if (tMatches) {
            tMatches.forEach(match => {
                const keyMatch = match.match(/['"]([a-zA-Z0-9_.]+)['"]/);
                if (keyMatch) {
                    const key = keyMatch[1];
                    if (!validateKey(key, section, relativePath, lineNumber)) {
                        hasErrors = true;
                    }
                }
            });
        }

        if (partsMatches) {
            partsMatches.forEach(match => {
                const keyMatch = match.match(/['"]([a-zA-Z0-9_.]+)['"]/);
                if (keyMatch) {
                    const key = keyMatch[1];
                    if (!validateKey(key, section, relativePath, lineNumber)) {
                        hasErrors = true;
                    }
                }
            });
        }
    });

    return !hasErrors;
}

// Function to display validation results
function displayResults() {
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
        console.log('\nErrors:');
        errors.sort(sortByLocation).forEach(error => console.error(error));
    }

    // Group warnings by key, section, and location
    if (warnings.length > 0) {
        console.log('\nWarnings:');
        
        // Create a map to group warnings
        const warningGroups = new Map();
        
        warnings.forEach(warning => {
            const match = warning.match(/Warning: Missing translation for key '([^']+)' in language '([^']+)' section '([^']+)' \((.*?):(\d+)\)/);
            if (match) {
                const [, key, lang, section, file, line] = match;
                const groupKey = `${key}:${section}:${file}:${line}`;
                
                if (!warningGroups.has(groupKey)) {
                    warningGroups.set(groupKey, {
                        key,
                        section,
                        file,
                        line,
                        languages: new Set()
                    });
                }
                warningGroups.get(groupKey).languages.add(lang);
            }
        });

        // Convert the map to array and sort by file and line
        const groupedWarnings = Array.from(warningGroups.values())
            .sort((a, b) => {
                if (a.file !== b.file) {
                    return a.file.localeCompare(b.file);
                }
                return parseInt(a.line) - parseInt(b.line);
            });

        // Display grouped warnings
        groupedWarnings.forEach(group => {
            const languages = Array.from(group.languages).sort().join("', '");
            console.warn(`Warning: Missing translation for key '${group.key}' in languages '${languages}' section '${group.section}' (${group.file}:${group.line})`);
        });
    }

    // Display summary
    console.log(`\nValidation summary: ${errors.length} errors, ${warnings.length} warnings`);
}

// Main function
function main() {
    console.log('Validating translations...');

    // Find all Swift files - search from parent directory
    const swiftFiles = glob.sync('../Bitkit/**/*.swift', { cwd: __dirname });
    
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
    displayResults();

    if (hasErrors) {
        console.error('\nValidation failed! See errors above.');
        process.exit(1);
    } else {
        console.log('\nValidation successful! All translations are properly configured.');
        process.exit(0);
    }
}

main(); 