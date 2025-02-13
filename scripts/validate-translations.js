const fs = require('fs');
const path = require('path');
const glob = require('glob');

// Collection of all errors and warnings
const errors = [];
const warningMap = new Map(); // key -> Set of languages

// Function to process a Swift file
function processSwiftFile(filePath) {
    let hasErrors = false;
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n');

    // First check if the file uses translations
    const hasTranslations = content.includes('NSLocalizedString(');
    if (!hasTranslations) {
        return true; // Skip files without any translation calls
    }

    // Get relative path for error reporting
    const relativePath = path.relative(path.join(__dirname, '..'), filePath);

    // Find all translation keys
    lines.forEach((line, index) => {
        const lineNumber = index + 1;
        const nsLocalizedMatches = line.match(/NSLocalizedString\(['"]([a-zA-Z0-9_]+)['"]/g);

        if (nsLocalizedMatches) {
            nsLocalizedMatches.forEach(match => {
                const keyMatch = match.match(/['"]([a-zA-Z0-9_]+)['"]/);
                if (keyMatch) {
                    const key = keyMatch[1];
                    // Check if the key exists in the .strings file
                    const stringsPath = path.join(__dirname, '..', 'Bitkit', 'Resources', 'Localization', 'en.lproj', 'Localizable.strings');
                    try {
                        const stringsContent = fs.readFileSync(stringsPath, 'utf8');
                        if (!stringsContent.includes(`"${key}" =`)) {
                            errors.push(`Error: Missing required English translation for key '${key}' in Localizable.strings (${relativePath}:${lineNumber})`);
                            hasErrors = true;
                        } else {
                            // Check other languages
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
                                    console.log(`Error reading ${lang}:`, error.message);
                                    const warningKey = `${key}:${relativePath}:${lineNumber}`;
                                    if (!warningMap.has(warningKey)) {
                                        warningMap.set(warningKey, new Set());
                                    }
                                    warningMap.get(warningKey).add(lang);
                                }
                            });
                        }
                    } catch (error) {
                        errors.push(`Error: Could not read Localizable.strings file: ${error.message}`);
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

    // Display warnings
    if (warningMap.size > 0) {
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

    // Display summary
    console.log(`\nValidation summary: ${errors.length} errors, ${warningMap.size} warnings`);
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