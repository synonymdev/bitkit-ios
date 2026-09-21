const apn = require('@parse/node-apn');

const { defaultPaymentAlert, appBundleID, config } = require('./settings');

// Matches the 28 day expiry the previous push wrapper applied by default.
const DEFAULT_TTL_SECONDS = 28 * 86400;

const createPushData = (payload) => {
    return new apn.Notification({
        topic: appBundleID,
        // The notification service extension reads the encrypted blob from aps.alert.payload,
        // so this has to stay nested inside the alert rather than sit in the custom payload.
        alert: {
            ...defaultPaymentAlert,
            payload
        },
        priority: config.push.priority,
        contentAvailable: config.push.contentAvailable,
        mutableContent: config.push.mutableContent,
        badge: config.notification.badge,
        sound: config.notification.sound,
        expiry: Math.floor(Date.now() / 1000) + DEFAULT_TTL_SECONDS,
        payload: {}
    });
};

module.exports = { createPushData };
