# Contacts

`delete-newly-saved-contact.xml` checks deletion directly from Contact Saved and adding that
contact again. It is mirrored on Android. Deleted contact screens must not remain in Back history.

`contacts-entry-points.xml` checks onboarding without an identity and the authenticated
Contacts list. It has not yet been ported to Android. Saved-identity recovery from the
drawer and Contacts intro, pending lookup, and leaving while lookup waits require storage
or network fault injection, which the journey runner does not provide. Check those cases
using the PR manual checks.

Import journeys require a disposable identity with a known following list. They save Bitkit contacts; payment sharing remains a separate step.

Continue waits for public payment setup, not private linking with every imported contact.
Private preparation runs in the background. Repeat Import All with a large following list containing
unavailable profiles, then delete a contact while preparation is running. It must not be republished
after deletion. Unavailable private-link lookups are retried after five minutes rather than on each refresh.

Network and storage fault injection are outside journey-runner capabilities. After the preview has
loaded, verify that importing its prepared contacts does not repeat profile lookups; saving shared
contact state still requires Pubky storage access. Simulate a failed contact batch: stay on import,
preserve previously saved contacts, and retry the entire unsaved selection without claiming partial
success. Duplicate selections and contacts already saved are skipped. Payment sharing remains a
separate step. On Android, a failed Continue on the payment-sharing screen should offer recovery
guidance and leave saved contacts intact.

Repeat both import journeys after deleting the disposable profile and adopting the same identity
again, including the 62-contact case. Record Import All to the payment-sharing screen separately
from Continue; there is no guaranteed network completion deadline. Explicit re-import saves the
selected contacts and removes their blocks atomically, without restoring old private links.
Deselected contacts remain blocked. Ordinary label updates must not remove a block. SDK failure
and cancellation coverage verifies that the app does not issue compensating block writes after
an atomic save, including when cancellation hides a completed commit.

`ContactImportUITests.swift` checks pending imports using the DEBUG-only `-contact-import-ui-test`
fixture. It holds the contact batch until the test taps Finish save, without network or SDK
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

Hold deletion cleanup after a contact disappears from the list, then open that contact's Add
screen using its deep link. Release cleanup: the Add screen must remain open and Save must
still work. Repeat from Edit Contact and while viewing a different contact. Cleanup from the
deleted contact must not replace the newer navigation destination.

Make a Contact Pay lookup fail with SDK contention, on both Contact Detail and the Send contact
picker. Verify the error uses localized retry guidance rather than SDK codes or context. A canceled
lookup must not display an error. Restore access and retry; payment validation must run again.
