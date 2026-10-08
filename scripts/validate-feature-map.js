// Fails when a file in Docs/features/ names a repository path that does not exist, so a moved or deleted
// file is caught in the PR that moved it and the feature file is updated with it.
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const featureDir = path.join(root, 'Docs', 'features');
// Backticked paths that start at the repo root; bitkit-e2e-tests/... paths belong to the sibling repo.
const REPO_PATH = /`((?:Bitkit|BitkitTests|BitkitUITests|BitkitWidget|BitkitNotification|Docs|journeys|scripts|\.github)\/[^`\s]+)`/g;

const missing = [];
const files = fs.readdirSync(featureDir).filter((name) => name.endsWith('.md')).sort();
for (const name of files) {
    const text = fs.readFileSync(path.join(featureDir, name), 'utf8');
    for (const match of text.matchAll(REPO_PATH)) {
        const ref = match[1].split(':')[0].replace(/\/$/, '');
        if (/[<*{]|\.\.\./.test(ref)) continue;
        if (!fs.existsSync(path.join(root, ref))) missing.push(`${name}: ${ref}`);
    }
}

if (files.length === 0) {
    console.error('No feature files found in Docs/features');
    process.exit(1);
}
if (missing.length > 0) {
    console.error('Docs/features names paths that do not exist; update the feature file:');
    for (const line of missing) console.error(`  ${line}`);
    process.exit(1);
}
console.log(`Docs/features: every named path exists (${files.length} files)`);
