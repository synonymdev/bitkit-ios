const PushNotifications = require('node-pushnotifications');

const { pushSettings, config } = require('./settings');
const { createPushData } = require('./helpers');

const push = new PushNotifications(pushSettings);

const deviceToken = config.device.token;

if (!deviceToken) {
    console.error('❌ No device token configured. Please set DEVICE_TOKEN in your .env file.');
    process.exit(1);
}

const data = createPushData({ type: 'payment' });

console.log("🚀 Sending test notification...");

push.send(deviceToken, data)
    .then((results) => {
        if (results[0].success) {
            console.log('✅ SENT!');
            return;
        }

        console.log("❌ No success from APS.");
        console.error(JSON.stringify(results));
    })
    .catch((error) => {
        console.error("❌ Error sending push notification.");
        console.log(JSON.stringify(error));
    })
    .finally(() => {
        console.log("🏁 Done.");
        process.exit(0);
    });
