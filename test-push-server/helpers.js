const { defaultPaymentAlert, appBundleID } = require('./settings');

const createPushData = (payload) => {
    return {
        topic: appBundleID,
        title: defaultPaymentAlert.title,
        body: defaultPaymentAlert.body,
        alert: { // iOS only
            ...defaultPaymentAlert,
            payload
        },
        priority: 'high',
        contentAvailable: 1,
        mutableContent: 1,
        badge: 0,
        sound: 'ping.aiff',
    };
};

module.exports = {createPushData};
