const PushNotifications = require('node-pushnotifications');

const { pushSettings } = require('./settings');
const { createPushData } = require('./helpers');

const push = new PushNotifications(pushSettings);

const hardcodedpushtoken = "1c3ceed3ef0eaacf9ec0dd03a4fe38c6cad60b5259d8e03efe3aa049e5e5ba89";

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
