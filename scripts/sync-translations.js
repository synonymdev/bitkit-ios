const fs = require('fs').promises;
const path = require('path');
const https = require('https');

const GITHUB_RAW_BASE = 'https://raw.githubusercontent.com/synonymdev/bitkit/master/src/utils/i18n/locales';
const LOCAL_DIR = path.join('Bitkit', 'Resources', 'Localization');

const LANGUAGES = [
    'arb', 'ca', 'cs', 'de', 'el', 'en', 'es_419', 'es_ES', 'fa', 'fr',
    'it', 'ja', 'ko', 'nl', 'no', 'pl', 'pt_BR', 'pt_PT', 'ro', 'ru', 'uk', 'yo'
];

const SECTIONS = [
    'onboarding', 'wallet', 'common', 'settings', 'lightning', 'cards', 'fee'
];

// Helper function to download a file
function downloadFile(url) {
    return new Promise((resolve, reject) => {
        https.get(url, (response) => {
            if (response.statusCode !== 200) {
                reject(new Error(`Failed to download: ${response.statusCode}`));
                return;
            }

            // Set encoding to utf8 to properly handle special characters
            response.setEncoding('utf8');
            let data = '';
            response.on('data', (chunk) => data += chunk);
            response.on('end', () => resolve(data));
        }).on('error', reject);
    });
}

async function main() {
    try {
        // Create directories for each language
        for (const lang of LANGUAGES) {
            const dirPath = path.join(LOCAL_DIR, lang);
            await fs.mkdir(dirPath, { recursive: true });
        }

        // Download files for each language and section
        for (const lang of LANGUAGES) {
            console.log(`Downloading files for language: ${lang}`);

            for (const section of SECTIONS) {
                const url = `${GITHUB_RAW_BASE}/${lang}/${section}.json`;
                const outputPath = path.join(LOCAL_DIR, lang, `${lang}_${section}.json`);

                try {
                    console.log(`Fetching ${url}`);
                    const data = await downloadFile(url);
                    await fs.writeFile(outputPath, data, 'utf8');
                    console.log(`✅ Downloaded ${section}.json for ${lang}`);
                } catch (error) {
                    console.log(`❌ Failed to download ${section}.json for ${lang}`);
                    console.error(error.message);
                }
            }
        }

        console.log('Done! 🎉');
    } catch (error) {
        console.error('Error:', error.message);
        process.exit(1);
    }
}

main(); 