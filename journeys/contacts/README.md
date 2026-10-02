# Contacts

Import journeys require a disposable identity with a known following list. They save local Bitkit contacts; payment sharing remains a separate step.

Network and storage fault injection are outside journey-runner capabilities. Manually disable
connectivity after the preview has loaded: importing the prepared contacts must still finish.
Simulate a failed local save: stay on import, preserve successful saves, and retry only missing
contacts without claiming complete success. On Android, a failed Continue on the payment-sharing
screen should offer recovery guidance and leave saved contacts intact.

`ContactImportUITests.swift` checks pending imports using the DEBUG-only `-contact-import-ui-test`
fixture. It holds the first local save until the test taps Finish save, without network or SDK
storage. The tests drive the real overview and selection views, attempt repeated import taps, and
verify that Select stays disabled, the preview stays intact, and completion saves the chosen contacts.
This controlled fixture is separate from the identity-backed journeys above.

Repeat both import journeys with an identity that follows itself. The preview count and selection
list must exclude your own profile, while other followed profiles can still be imported. Your own
profile must also be absent from the saved contacts.

## Contact payment sharing

`contact-payment-sharing.xml` checks disabling sharing and keeping it off after returning to
Settings.

Network and storage fault injection are outside journey-runner capabilities. With contact sharing
on, make one private-list withdrawal fail and let the following public endpoint or app-registry
update fail as well. Turn off contact payments. The app must report the failure, keep the toggle off,
and retain both cleanup jobs without republishing cleared private lists. Restore connectivity and
foreground the app. Cleanup must finish while sharing stays off. Repeat with only the trailing
public endpoint or app-registry update failing.
