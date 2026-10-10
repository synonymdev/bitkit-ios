# Activity

`localized-plural-headings.xml` checks the input/output headings with the actual transaction details
loaded in Polish, French, and English. Use a disposable regtest wallet and an existing transaction
with one input and two outputs; the journey does not send payments. Record its transaction ID first.

Restore the original language at the end. Language Settings names its rows in English even when
the app is translated, and the language-change alert requests a restart. Use identifiers to reach
Settings, Language, transaction details, and the transaction ID; localized tab identifiers should
not be relied on after switching languages.

This is an iOS regression: Android already resolves the same ICU translations. Russian backup
plural forms, fallback language selection, and the remaining activity translations are covered by
`LocalizationPluralTests.swift` without inducing backup failures.
