const PushNotifications = require('node-pushnotifications');

const { pushSettings } = require('./settings');
const { createPushData } = require('./helpers');

const push = new PushNotifications(pushSettings);

const hardcodedpushtoken = "df6a15e37fe90bd0f71e919823ea19171e30fbc5632130e5e8e68f17dc76105e";

const data = createPushData({
    type: 'payment'
});

console.log("Sending test");
push.send(hardcodedpushtoken, data)
    .then((results) => {
        if (results[0].success) {
            console.log('SENT!');
            return;
        }

        console.log("No success from APS.");
        console.error(JSON.stringify(results));
    })
    .catch((error) => {
    console.error("Error sending push notification.");
    console.log(JSON.stringify(error));
}).finally(() => {
    console.log("Done.");
    process.exit(0);
});
