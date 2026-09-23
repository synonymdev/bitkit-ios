# Bitkit iOS push tests

`send-wake-probe.mjs` sends directly to APNs using Node.js built-ins. It does not
need `npm install` and never reads the stale `DEVICE_TOKEN` or `APP_BUNDLE_ID`
values from an existing `.env` file.

Create `test-push-server/.env` with the Apple APNs signing key settings:

```text
APN_KEY_ID=your-key-id
APN_TEAM_ID=your-team-id
APN_KEY_FILE=./AuthKey.p8
APN_PRODUCTION=false
```

The key path is relative to this directory. Keep the `.p8` file and `.env`
private; both are gitignored. A Debug build signed for development needs
`APN_PRODUCTION=false`. The app topic defaults to `to.bitkit`; override it
with `BITKIT_APN_TOPIC` only if the installed app has a different bundle ID.

From this directory, set the current iPhone token in your shell and send a
silent background push:

```sh
export BITKIT_DEVICE_TOKEN=<current-64-character-token>
node --env-file=.env send-wake-probe.mjs wake
```

The experimental app records the callback and observed node state in its
`Documents/background-wake-probe.json` file, and also tries to copy it to the
`group.bitkit` app group. It refreshes LDK's peer state, attempts to reconnect
peers, and keeps the callback open for up to about 23 seconds while checking
whether the count of settled inbound payments increases. These counts are
diagnostic only; they are not tied to a specific invoice and must not be used
as a production payment acknowledgement. A successful APNs HTTP response means
Apple accepted the push; it does **not** prove the phone received it or ran the
callback. Background pushes may be delayed or dropped.

For the two-push diagnostic, send an unconditional visible fallback after a
15-second delay:

```sh
node --env-file=.env send-wake-probe.mjs pair
```

Set `WAKE_FALLBACK_DELAY_MS` to change the delay (0–60000 ms). The fallback is
deliberately unconditional: this test does not know whether a payment settled,
so it must not be used as a production notification policy. `alert` sends only
the visible fallback. Avoid repeated silent pushes in a short period; iOS may
throttle or coalesce them. APNs may also reorder the two pushes in `pair` mode.
