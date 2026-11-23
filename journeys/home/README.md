# Home

- `pull-to-refresh-rates.xml` checks exchange-rate refresh and the pull-to-refresh layout.
- `timed-reminders-do-not-interrupt.xml` checks that optional reminders do not replace an open
  scanner or sheet; see the Porting from Android section of `journeys/README.md`.
- `cold-start-activity.xml` checks that recent transactions and All Activity remain consistent
  across a cold launch. This is an iOS-specific cache regression; it does not change Android
  behaviour. `BoostTxIdsCacheTests.swift` deterministically proves scan coalescing, retry,
  last-successful-value fallback after refresh failure, and strict invalidation because a UI
  journey cannot count internal database reads or inject a cache-load failure.
