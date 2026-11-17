const apn = require('@parse/node-apn');

const { providerOptions, config } = require('./settings');
const { fetchRecordedPush, createPushData } = require('./helpers');

const main = async () => {
    const recorded = await fetchRecordedPush(config.device.token);
    if (!recorded) {
        console.error('❌ The fake APNs recorded no push for this device. Register it and send a wake first.');
        process.exit(1);
    }

    const notification = createPushData(recorded);
    console.log(`🚀 Relaying push #${recorded.seq}: ${notification.pushType}, priority ${notification.priority}`);

    if (config.dryRun) {
        console.log(JSON.stringify({ headers: notification.headers(), body: notification.rawPayload }, null, 2));
        return;
    }

    const provider = new apn.Provider(providerOptions);
    try {
        const result = await provider.send(notification, recorded.token);
        if (result.sent.length > 0) {
            console.log('✅ SENT!');
        } else {
            console.log('❌ No success from APS.');
            console.error(JSON.stringify(result.failed));
        }
    } finally {
        provider.shutdown();
    }
};

main()
    .catch((error) => {
        console.error('❌ Error sending push notification.');
        console.error(error);
        process.exitCode = 1;
    })
    .finally(() => console.log('🏁 Done.'));
