# Profile

`delete-profile.xml` verifies visible progress and completion when deleting a disposable profile. Use a test identity that may be deleted.

During profile deletion, automatic contact refresh, request intake and endpoint publication must not start new work. Already admitted operations and explicit deletion cleanup still finish. After a failed deletion, normal automatic work must resume for the retained identity. Verifying SDK admission and a controlled cleanup failure requires operation gates beyond the journey runner capabilities; this remains a manual check rather than a timed deletion guarantee.

With a contact link held during deletion, let deletion succeed and verify that the retained link opens the public contact profile while signed out, without a QR error or a private contact-list read. For failed deletion, hold contact preparation until after cleanup fails, then release it and verify that the retained link retries once preparation is available without a repeated error loop. Controlling this ordering requires preparation and cleanup-failure gates beyond the journey runner capabilities.

If public invoice replacement is deferred during deletion, make deletion fail and the first resumed publication fail transiently. Verify that public publication resumes without waiting for contact refresh to complete, remains pending after the publication error, and is retried by normal foreground maintenance without another foreground event or payment. After sign-out, identity replacement, cancellation or disabled public sharing, an older failed refresh must not mark new publication work pending. Controlled payment events and publication failures require gates beyond the journey runner capabilities.

Hold invoice preparation or the final identity lookup before publication, begin deletion, then release it. New public/private endpoint rotation must stay deferred while matching paid-invoice invalidation and receipt attribution still complete. Already-admitted writes may finish, but an older publication must not acknowledge a newer paid-invoice invalidation. These checks require controlled payment events and SDK-admission gates beyond the journey runner capabilities.

Hold endpoint preparation before publication admission, or queue a public publication behind SDK work. Begin deletion, complete endpoint removal while session revocation remains held, then release the queued preparation/publication. The removed endpoints must stay absent. Separately, let a publication enter its SDK write before deletion: cleanup must wait for it and remove its endpoints afterward, even if its caller is cancelled. This requires controlled operation gates beyond the journey runner capabilities.

On iOS, public publication and endpoint removal share an endpoint lock. A publication already holding that lock while waiting for SDK work must finish or stop before removal can complete. Hold preparation before that lock to exercise removal before a stale publication is released. Explicit manual sharing settings are outside these automatic-publication checks.

Hold initial session restoration with public contact payments enabled, turn contact payments off, then release restoration. No automatic endpoint preparation or publication may resume, and pending cleanup must remain available. Repeat with publication waiting for SDK admission. If a write was already admitted, let it finish and verify it cannot clear the cleanup requested by disabling sharing. These checks require restoration and SDK-operation gates beyond the journey runner capabilities.

`signup-create-profile.xml` verifies that signup through staging.pubky.app can finish profile creation without a false Profile Error toast. Use a fresh, unfunded test wallet and keep the app process alive. The profile must use the same public key as the authorized signup.

Delayed or failed session restoration requires network fault injection, which is not a journey-runner capability; see the PR manual checks.

For a saved identity, inject a temporary import failure (`concurrent_update`, `shared_state_busy`, or a transport failure) during cold start. Verify that no "Session expired" toast appears, the saved credentials remain, and recovery succeeds after the temporary failure ends. A genuinely invalid session must still produce the existing expiry feedback.

For the reported background-resume case, verify returning directly to Profile with the process still alive, then repeat after the OS recreates the process. A delay in session recovery must keep the saved identity on the profile loading/retry screen rather than show profile onboarding.

On iOS, open a saved contact's link while a stored identity's session restoration is held, deferred or failed. The link must stay pending without opening Add Contact, reading private contacts or showing a QR error. Restore the session and verify that the retained link opens the saved contact once contacts are ready, without opening the link again. With no stored identity, including after successful profile deletion, the public contact must still open read-only without granting authentication. A cached profile name alone is not a stored identity. These checks require restoration and network-failure gates beyond the journey runner capabilities.
