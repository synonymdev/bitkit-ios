const apn = require('@parse/node-apn');

const { appBundleID, config } = require('./settings');

// The newest push the gateway's fake APNs recorded, for `token` when one is given.
const fetchRecordedPush = async (token) => {
    const response = await fetch(`${config.fakePush.url}/_recorded`);
    if (!response.ok) {
        throw new Error(`The fake APNs answered ${response.status}`);
    }
    const pushes = (await response.json())
        .filter((push) => push.platform === 'apns' && (!token || push.token === token))
        .sort((a, b) => b.seq - a.seq);
    return pushes[0];
};

// The recorded push as the gateway would send it to APNs: the same body, push type, priority, expiry and collapse id.
const createPushData = (recorded) => {
    const header = (name) => recorded.headers.find(([key]) => key === name)?.[1];
    const notification = new apn.Notification();
    notification.rawPayload = JSON.parse(recorded.raw_body);
    notification.topic = appBundleID;
    notification.pushType = header('apns-push-type');
    notification.priority = Number(header('apns-priority'));
    notification.expiry = Number(header('apns-expiration'));
    const collapseId = header('apns-collapse-id');
    if (collapseId) {
        notification.collapseId = collapseId;
    }
    return notification;
};

module.exports = { fetchRecordedPush, createPushData };
