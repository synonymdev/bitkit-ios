const pushSettings = {
    apn: {
        token: {
            key: './certs/AuthKey_DH6VTRG952.p8', // optionally: fs.readFileSync('./certs/key.p8')
            keyId: 'DH6VTRG952',
            teamId: 'KYH47R284B',
        },
        production: false // true for APN production environment, false for APN sandbox environment,
    },
    isAlwaysUseFCM: false, // true all messages will be sent through node-gcm (which actually uses FCM)
};

const defaultPaymentAlert = {
    title: 'Incoming LN Payment failed',
    body: 'Please open app and ask sender to try again.'
}

const appBundleID = 'to.Bitkit.native';

module.exports = {pushSettings, defaultPaymentAlert, appBundleID};
