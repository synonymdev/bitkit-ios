const apn = require('@parse/node-apn');

const { providerOptions, config } = require('./settings');
const { createPushData } = require('./helpers');

const provider = new apn.Provider(providerOptions);

const deviceToken = config.device.token;

if (!deviceToken) {
    console.error('❌ No device token configured. Please set DEVICE_TOKEN in your .env file.');
    process.exit(1);
}

const notification = createPushData({ type: 'payment' });

console.log("🚀 Sending test notification...");

provider.send(notification, deviceToken)
    .then((result) => {
        if (result.sent.length > 0) {
            console.log('✅ SENT!');
            return;
        }

        console.log("❌ No success from APS.");
        console.error(JSON.stringify(result.failed));
    })
    .catch((error) => {
        console.error("❌ Error sending push notification.");
        console.log(JSON.stringify(error));
    })
    .finally(() => {
        provider.shutdown();
        console.log("🏁 Done.");
        process.exit(0);
    });
