# Contacts

`contacts-entry-points.xml` checks onboarding without an identity and the authenticated
Contacts list. It has not yet been ported to Android. Saved-identity recovery from the
drawer and Contacts intro, pending lookup, and leaving while lookup waits require storage
or network fault injection, which the journey runner does not provide. Check those cases
using the PR manual checks.

Import journeys require a disposable identity with a known following list. They save local Bitkit contacts; payment sharing remains a separate step.

Continue waits for public payment setup, not private linking with every imported contact.
Private preparation runs in the background. Repeat Import All with a large following list containing
unavailable profiles, then delete a contact while preparation is running. It must not be republished
after deletion. Unavailable private-link lookups are retried after five minutes rather than on each refresh.

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

Hold withdrawal in progress and foreground the app. It must not start another cleanup. Request
sharing on again before withdrawal finishes: publication must wait until the earlier cleanup ends,
then leave sharing on. Repeat while a foreground cleanup is already running.

## Foreground wait isolation

Hold an unrelated contact's background preparation in progress, then open a saved, linked contact
and request or pay it. The selected contact must be eligible for its own lookup before the full
contact scan finishes. Hold its public capability lookup separately: this public read must not
retain the shared-state operation queue used by payment resolution, withdrawal, and wallet backup.
Identity, link, and request execution checks still run and may wait for shared-state access.

Retry private messages for one contact while other contacts have pending outbound work. Only the
selected retry contacts should be sent to or read from in that drain. Repeat during sharing OFF,
with one withdrawal failing: OFF remains immediate, cleanup remains pending on failure, and no new
publication starts. Record action-to-result time separately from SDK lock and network waits; these
fault-injection checks do not establish staging latency or a guaranteed completion deadline.
