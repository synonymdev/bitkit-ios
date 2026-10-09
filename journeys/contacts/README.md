# Contacts

`link-contact-after-resume.xml` checks saving a new contact, leaving and reopening Bitkit, and
reaching Request or Pay without re-adding the contact. It is mirrored on Android and requires two
disposable, request-capable identities. Record readiness timing separately from a pass/fail result.
A natural run may finish linking before backgrounding; the controlled pending-operation checks
below are still needed to verify that pending work resumes.

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

## Contact synchronization overlap

Hold contact synchronization before private preparation or cleanup, then save a new contact and
start its explicit link retry. Release synchronization and verify that the contact stays saved,
its retry retains the original priority deadline, and the older contact list does not withdraw
its payment endpoints. On Android, hold the startup app-registry refresh; on iOS, hold public
publication while enabling contact payments and leave Settings to save the contact.

Repeat by removing and re-adding a contact while synchronization's cleanup is queued, then by changing identity.
Obsolete cleanup must not cancel the new retry or remove its assignments. A deletion that stays
current must still remove the contact. These checks require controlled operation blocking and
retry-state inspection, which the standard journey runner does not provide; record timing
separately from the correctness result.

## Background preparation

Sign in from Pubky Ring with a saved, request-capable contact while holding the selected
identity's profile lookup. After authentication and contact loading finish, Paykit target
discovery must run without waiting for the profile lookup or a maintenance poll. Verify the
Receive contact-request entry point once discovery finishes. Repeat with backgrounding or an
identity change during contact loading: automatic refresh must not start for an inactive app
or the previous identity. This requires Pubky Ring and controlled profile lookup timing,
which are not journey-runner capabilities. Android uses the same authenticated-identity gate.

With saved contacts and scheduled private preparation or retry work, press Home between SDK
operations. Saved contacts must remain intact; scheduled preparation and retries pause before
their next operation and resume on return to the app. Background the app while an SDK call is
held in progress: that call must finish without cancellation. Delete the disposable profile while
preparation is paused; returning to the app must not resume work for the old identity.

Controlled SDK blocking and lifecycle-boundary observations require an instrumented fixture,
which the standard journey runner does not provide. Record ordinary Home/resume separately;
it does not prove every controlled case. Do not delete a profile containing data to preserve.

On iOS, inactive transitions alone do not pause preparation. An admitted endpoint publication
batch finishes its reservations and publication together, even after backgrounding. Explicit
foreground preparation and cleanup remain ordered; scheduled work uses background priority.

Emit several proof-state notifications while backgrounded without changing proof persistence.
No observer-driven stored request refresh starts until the app is active; returning to the app
refreshes the latest state once. Repeat while payment activity is held: refresh waits until that
activity ends. A session change discards the old session's pending refresh. These notifications
and the payment-activity hold require the same controlled fixture, not a real payment.

Hold proof reconciliation during an automatic request refresh, then background the app and release
it. Reconciliation must finish, but request intake and target discovery wait for resume. Explicit
payment-completion work keeps its normal behavior. This requires controlled operation blocking.

Hold an explicit request send, payment-proof completion, or sharing withdrawal in progress, then
background the app and release the operation. It must continue without waiting for foreground
contact preparation. Acceptance delivery also remains eligible after payment submission ends.
These checks require controlled operation blocking and do not guarantee execution after OS
suspension or termination.

On iOS, backgrounding cancels the automatic polling and foreground-publication SwiftUI tasks;
they are distinct from explicit completion work. Dismissing a send flow can cancel preparation,
and session changes still stop obsolete work. A confirmed hardware broadcast must finish its
proof-completion callback even when the caller is canceled.

On iOS, pause contact preparation after a private invoice payment or reserved-address activity.
The received-payment marker must persist, and wallet sync and post-boost completion must not wait
for endpoint publication. Resume preparation and verify the updated endpoints are published.
Repeat while an older endpoint batch is held: the refresh must remain queued for a later batch.
These checks require controlled operation blocking.

With public sharing enabled, compare a retained-profile startup and Home/resume. Initial public
publication waits for the signed-in session and running node, with one automatic publication per
activation when receive endpoints and session inputs are unchanged. Changed receive endpoints and
forced channel invoice refresh still publish their latest values. Disable sharing or end the session
while app registration is held; the admitted write may
finish, but the next endpoint publication must not start for the ended session or disabled sharing.

## Foreground wait isolation

With one peer waiting at the ninety-second retry interval, explicitly add or refresh another
contact. Its retry age must start independently and wake the sleeping worker. Repeat the action
while its link operation is held: the operation is shared, and the twenty-second foreground
admission window is not extended. After expiry, subsequent SDK calls use background priority;
expiry and backgrounding must not cancel an admitted write. Resume after expiry, delete the
contact, and switch identity while work is paused to check stale work is discarded. These checks
need controlled clocks and SDK holds, outside the journey runner. On successful linked intake
during the window, only that contact's request eligibility is refreshed. Linked alone does not
prove that a usable incoming payment list exists. These checks establish scheduling behavior,
not device latency or a guaranteed link-completion deadline.

Fail identity inspection before linking and after an admitted write, then recover: the retry
keeps its existing backoff and window, and no further SDK work starts while identity is unverified.
For a linked peer with no outbound messages, failed intake keeps the explicit retry pending
within that window. After expiry, normal background drain rules apply without signaling readiness.
Target eligibility discovery remains owned by the existing request manager. It coalesces lookups
but does not automatically retry a failed targeted refresh; a later full refresh or contact
eligibility lookup can retry it. Successful intake does not guarantee successful discovery.

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
