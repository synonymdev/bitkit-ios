# LNURL journeys

## Setup

LNURL-pay needs a reachable LNURL server. Start the `lnurl-pay` fixture of a sibling `bitkit-docker`
checkout (a service with stable pay metadata whose invoice callback keeps returning an error until
it is switched healthy):

```bash
cd /path/to/bitkit-docker
docker compose --profile lnurl-pay up -d --build --wait lnurl-server-fixture
```

It serves on port 23010. Read the link to paste from it:

```bash
curl -fsS http://127.0.0.1:23010/generate/pay       # {"url":..., "lnurl":"lnurl1...", ...}
curl -fsS -X POST -H 'content-type: application/json' \
  -d '{"mode":"healthy"}' http://127.0.0.1:23010/fixture   # or "error"; it starts in "error"
```

The callback URLs it returns follow the address the request used, so a simulator that reaches the
server at another address (a per-seat loopback address, `E2E_LOCAL_HOST`) gets callbacks at that
address. Build the app with the E2E condition and local backend as in [`../README.md`](../README.md)
so it may call plain HTTP on the local network.

The fixture issues signed regtest invoices for fetching and decoding only. It has no Lightning
node and cannot settle a payment.

## What is not covered

Everything after the capacity check needs a Lightning spending balance: a channel to the LSP, which
the journey environment does not provide on an isolated stack. The failing and recovering invoice
callback (the send failure screen with a retry that succeeds once the callback is healthy) therefore
has no journey here yet. `payment-requests/definite-pre-broadcast-retry.xml` covers it for a
Payment Request on a wallet that has that balance.
