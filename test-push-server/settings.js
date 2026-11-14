const fs = require('fs');
require('dotenv').config();

// Load configuration from environment variables with fallbacks
const config = {
    apn: {
        keyId: process.env.APN_KEY_ID,
        teamId: process.env.APN_TEAM_ID,
        keyFile: process.env.APN_KEY_FILE,
        production: process.env.APN_PRODUCTION === 'true'
    },
    app: {
        bundleId: process.env.APP_BUNDLE_ID || 'to.bitkit'
    },
    device: {
        token: process.env.DEVICE_TOKEN
    },
    // The fake APNs of the wake gateway's docker stack, which records every push instead of sending it.
    fakePush: {
        url: process.env.FAKE_PUSH_URL || 'http://127.0.0.1:9100'
    },
    dryRun: process.env.DRY_RUN === 'true'
};

// Validate APN key file exists
if (!config.dryRun && !fs.existsSync(config.apn.keyFile || '')) {
    console.error(`❌ APN key file not found: ${config.apn.keyFile}`);
    console.error('Please ensure the key file exists and the path is correct.');
    process.exit(1);
}

const providerOptions = config.dryRun ? null : {
    token: {
        key: fs.readFileSync(config.apn.keyFile),
        keyId: config.apn.keyId,
        teamId: config.apn.teamId,
    },
    production: config.apn.production
};

module.exports = {
    providerOptions,
    appBundleID: config.app.bundleId,
    config
};
