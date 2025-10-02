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
        bundleId: process.env.APP_BUNDLE_ID
    },
    device: {
        token: process.env.DEVICE_TOKEN
    },
    notification: {
        title: 'Test Title',
        body: 'This is a test notification body',
        sound: 'ping.aiff',
        badge: 0
    },
    push: {
        priority: 'high',
        contentAvailable: 1,
        mutableContent: 1
    }
};

// Validate APN key file exists
if (!fs.existsSync(config.apn.keyFile)) {
    console.error(`❌ APN key file not found: ${config.apn.keyFile}`);
    console.error('Please ensure the key file exists and the path is correct.');
    process.exit(1);
}

const pushSettings = {
    apn: {
        token: {
            key: fs.readFileSync(config.apn.keyFile),
            keyId: config.apn.keyId,
            teamId: config.apn.teamId,
        },
        production: config.apn.production
    },
    isAlwaysUseFCM: false
};

const defaultPaymentAlert = {
    title: config.notification.title,
    body: config.notification.body
};

module.exports = {
    pushSettings,
    defaultPaymentAlert,
    appBundleID: config.app.bundleId,
    config
};
