# Push Notification Test Server

Sends a wake push to a real device through APNs, for testing the Bitkit iOS app on a device.

The wake gateway's docker stack (synonymdev/wake, `docker/compose.yml`) records every push in its fake APNs instead of
sending it. This server takes the newest recorded push and sends the same body to APNs with the same push type,
priority, expiry and collapse id, so the device receives the v1 shape the gateway would send: a background wake, an
alert or time-sensitive wake, or a fallback alert. The device decrypts it with the key it registered and acknowledges
it to the gateway.

## Setup

1. **Install dependencies:**
   ```bash
   npm install
   ```

2. **Configure environment:**
   Create a `.env` file in the project root (see `.env.example`):
   ```bash
   # Apple Push Notification Service Configuration
   APN_KEY_ID=your_key_id_here
   APN_TEAM_ID=your_team_id_here
   APN_KEY_FILE=./path/to/your/AuthKey.p8
   # false for a debug build, whose token comes from the APNs sandbox
   APN_PRODUCTION=false

   # App Configuration
   APP_BUNDLE_ID=to.bitkit

   # Optional: the device token to relay pushes for. Without it, the newest recorded push is relayed.
   DEVICE_TOKEN=

   # Optional: the fake APNs of the wake docker stack
   FAKE_PUSH_URL=http://127.0.0.1:9100
   ```

3. **Add your APN key file:**
   - Place your `.p8` key file in the project directory
   - Update `APN_KEY_FILE` in your `.env` file to point to it

4. **Run the gateway and register the device:**
   - Start the wake docker stack with `docker compose -f docker/compose.yml --profile dev up -d --build --wait`.
     Its ports are published on loopback, so publish 9010 on an address the device can reach.
   - Launch a debug build on the device with the launch argument `-WAKE_GATEWAY_URL http://<host>:9010`, turn
     notifications on, and use Dev Settings > Wake > Register Now.

## Usage

Make the gateway push something, then relay it:

```bash
# An alert the notification extension handles: Dev Settings > Wake > Send Test Wake, then
node index.js

# Print what would be sent without sending it
DRY_RUN=true node index.js
```

## Troubleshooting

- **"APN key file not found"**: Ensure your `.p8` key file exists and the path is correct
- **"The fake APNs recorded no push"**: Register the device with the local gateway and make it push something first
- **Push notification fails**: Check that your device token is valid, that `APN_PRODUCTION` matches the build, and
  that your APN credentials are correct
