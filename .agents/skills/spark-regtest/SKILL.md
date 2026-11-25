---
name: spark-regtest
description: >
  This skill should be used when running a Bitkit iOS dev build on Spark's regtest: building it for
  Spark, funding Savings or the Spark (Spending) balance, paying between dev builds, Move to Spark,
  or Spark emergency exit tests. Triggers: "spark regtest", "local spark", "fund spark",
  "spark faucet", "spark deposit address", "Transfer Unavailable", "SPARK_LOCAL_CONFIG_B64",
  "./spark", "Lightspark regtest".
---

# Spark regtest

Dev builds run Spark through the Breez SDK. Two Spark regtest networks exist, and neither shares a chain with Blocktank's
staging regtest (`stag0.blocktank.to`). Coins and Lightning payments never cross between them.

| | Lightspark hosted (default) | Local `./spark` (bitkit-docker) |
| --- | --- | --- |
| Use for | Quick checks, physical phones, two-device Spark payments | Lightning to or from a node you control, Move to Spark with a channel, emergency exits, offline E2E |
| Lightning | Only through Lightspark's provider; no node you control | Alice, a Lightning node with a channel to the provider |
| Chain | Lightspark's own | bitkit-docker's local regtest (`spark-bitcoind` peers with `bitcoind`) |
| Funding | Faucet | `./spark pay`, `./spark send` |
| Docs | bitkit-android `scripts/spark-regtest-fund.py` (header) | `bitkit-docker/docs/spark-regtest.md` |

Sibling checkouts are assumed next to this repo (`../bitkit-android`, `../bitkit-docker`, `../bitkit-e2e-tests`); from a
worktree, use the main checkout's siblings. Run `./spark` commands from bitkit-docker. Read the named docs and script
headers for details. The steps below are what is not obvious from them.

## Lightspark hosted regtest

1. A Debug regtest build connects with no key.
2. iOS has no `ESPLORA_URL` setting like Android's, so Savings stays on Blocktank's staging chain and Transfer to
   Spending shows the Transfer Unavailable sheet. Fund Spark's deposit address directly. It is on Settings › Advanced ›
   Lightning Connections › Spark.
3. Fund:
   - Web faucet: https://app.lightspark.com/regtest-faucet, up to 50,000 sats per deposit. The user submits it in a
     browser.
   - Script: `SPARK_REGTEST_MNEMONIC=… uv run ../bitkit-android/scripts/spark-regtest-fund.py <bcrt1… address> [sats]`.
     The mnemonic is a GitHub secret; ask the user, never print it.
4. Lightspark mines about once a minute. Spark claims a deposit after 3 confirmations unless an Instant transfer claims
   it early.
5. Two-device payment: fund the payer's Spark balance, copy the invoice from Receive › Spending on the other dev build,
   and pay it from the payer. It goes over Lightning through Lightspark's provider.

## Local `./spark` stack

Run `./spark up` from a bitkit-docker checkout on `main`. The app reads `SPARK_LOCAL_CONFIG_B64` and
`SPARK_LOCAL_CHAIN_URL` only in a Debug regtest build that runs as E2E (`E2E_BUILD`, or launch env `E2E=true`) with
`E2E_BACKEND=local` (`Env.localSparkSettings`). Otherwise it silently stays on the hosted regtest. bitkit-e2e-tests'
build script sets all of that:

```bash
../bitkit-docker/spark up && \
IOS_ROOT="$PWD" && cd ../bitkit-e2e-tests && \
CFG="$(../bitkit-docker/spark config --base64)" && \
IOS_ROOT="$IOS_ROOT" SPARK_LOCAL_CONFIG_B64="$CFG" \
SPARK_LOCAL_CHAIN_URL=http://127.0.0.1:23090/api BACKEND=local ./scripts/build-ios-sim.sh && \
xcrun simctl install booted aut/Bitkit.app
```

- The `&&` chain stops at the first failure. `spark up` can fail while a config from an earlier run survives, and
  `spark config` fails when the stack is not up or the `bitkit-docker` path is wrong; inline, the build would still run.
- The two settings are `Info.plist` build settings, baked in at build time. `SIMCTL_CHILD_` launch variables don't set
  them, despite what `docs/spark-regtest.md` says.
- The simulator shares the Mac's loopback, so the `127.0.0.1` URLs work as they are. Savings uses bitkit-docker's
  Electrum, the same chain, so Transfer to Spending and Savings-paid exit fees work (`Env.sharesLocalSparkChain`).
- `IOS_ROOT` keeps the script on this checkout; it defaults to the `bitkit-ios` checkout next to bitkit-e2e-tests.
- A simulator that already chose an Electrum server keeps it, and Savings then misses the fixture chain. Uninstall the
  app first, or use Settings › Advanced › Electrum Server › Reset To Default.
- Fund Spark with `./spark send <deposit address> <sats>` or `./spark pay <Spending invoice> [sats]`.
- A deposit is claimed after 1 block here.
- Mine with `./spark mine`, not `./bitcoin-cli mine`: only `spark-bitcoind` relays Spark's v3 packages.
- bitkit-e2e-tests' `README.md` (Spark tests on local regtest) runs the same stack from its pinned
  `BITKIT_DOCKER_REVISION`, not your checkout.

Regtest needs no `BREEZ_API_KEY`. For mainnet builds see `README.md`.
