# Push Notification Test Server

A simple Node.js server for testing push notifications with the Bitkit iOS app.

## Setup

1. **Install dependencies:**
   ```bash
   npm install
   ```

2. **Configure environment:**
   Create a `.env` file in the project root with your custom values:
   ```bash
   # Apple Push Notification Service Configuration
   APN_KEY_ID=your_key_id_here
   APN_TEAM_ID=your_team_id_here
   APN_KEY_FILE=./path/to/your/AuthKey.p8
   APN_PRODUCTION=false

   # App Configuration
   APP_BUNDLE_ID=your.app.bundle.id

   # Test Device Token (replace with your actual device token)
   DEVICE_TOKEN=your_device_token_here
   ```

3. **Add your APN key file:**
   - Place your `.p8` key file in the project directory
   - Update `APN_KEY_FILE` in your `.env` file to point to it

## Usage

```bash
node index.js
```

## Troubleshooting

- **"APN key file not found"**: Ensure your `.p8` key file exists and the path is correct
- **"No device token configured"**: Set `DEVICE_TOKEN` in your `.env` file
- **Push notification fails**: Check that your device token is valid and your APN credentials are correct
