const PushNotifications = require('node-pushnotifications');

const { pushSettings } = require('./settings');
const { createPushData } = require('./helpers');

const push = new PushNotifications(pushSettings);

const hardcodedpushtoken = "2933593c23394bd98e9f319082ff4b4f7bcc5e553865fb02b57fbb6ca8c6ce07";

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
