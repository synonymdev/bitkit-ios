# Profile

`delete-profile.xml` verifies visible progress and completion when deleting a disposable profile. Use a test identity that may be deleted.

`signup-create-profile.xml` verifies that signup through staging.pubky.app can finish profile creation without a false Profile Error toast. Use a fresh, unfunded test wallet and keep the app process alive. The profile must use the same public key as the authorized signup.

Delayed or failed session restoration requires network fault injection, which is not a journey-runner capability; see the PR manual checks.

For the reported background-resume case, verify returning directly to Profile with the process still alive, then repeat after the OS recreates the process. A delay in session recovery must keep the saved identity on the profile loading/retry screen rather than show profile onboarding.
