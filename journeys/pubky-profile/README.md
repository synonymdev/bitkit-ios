# Pubky profile loading

This suite covers what Profile, the Pubky Ring choice screen and Contacts show while profiles are
still loading from the network, and a contact import that finishes after you leave it. Importing
contacts itself is covered by [`journeys/contacts`](../contacts/README.md). Where Android differs, see
[iOS vs Android](#ios-vs-android).

- `cached-profile-header.xml` opens Profile straight after a relaunch, while the signed-in profile is
  still loading. Profile shows the name cached from the last load, read-only, then swaps in the full
  profile in place.
- `ring-choice-rows.xml` opens the choice screen with Pubky Ring identities. The rows show straight
  away under truncated keys and fill in names as each lookup finishes. While a row's lookup runs, a
  spinner stands in for its avatar, so a row still looking up does not look like a row whose
  identity has no profile. A lookup for an identity with no profile can take several seconds to give
  up. Tapping a row adopts that identity: only the tapped row shows a spinner, and every row is
  disabled until adoption finishes.
- `contact-import-after-leaving.xml` adopts a Ring identity with many follows, taps Import All and
  leaves the import overview straight away. Leaving does not stop the import, and an import that
  finishes after you left does not take you to Pay Contacts. Contacts then lists every follow.
- `contacts-list-loading.xml` relaunches and opens Contacts. The saved contacts show straight away
  under the names they were saved with, and each fills in its profile name and avatar as its lookup
  finishes. The rows fill in a few at a time, at most every 300 ms, rather than the list re-sorting
  once per contact. Reopening Contacts in the same session shows the profiles already found straight
  away, and does not look up again a profile found less than ten minutes ago, so only contacts still
  without a profile get a new lookup. Opening a contact whose profile has not loaded yet looks it up
  at once, and its edit form shows the published bio.

## Preconditions

Every journey needs an onboarded E2E Bitkit build with Paykit UI enabled. Use the test simulator UDID
for `<UDID>`.

**Cached profile header.** A Bitkit-generated Pubky identity whose profile has a name, as in the
Pubky identity row of the Capabilities table in [`journeys/README.md`](../README.md). Profile must
have loaded fully once on this build, so the cache records which key the name belongs to. A cache
written before the owner was recorded, or for another key, shows the plain spinner instead of the
header.

**Ring choice rows.** Pubky Ring is **not** in the Capabilities table, so the reviewer supplies it:

- Pubky Ring installed on the same simulator or device and signed by the same Apple team, so it
  shares Bitkit's `pubky.shared` keychain group. Bitkit has no way to seed Ring records itself.
- At least two identities in Pubky Ring, at least one with a profile name published where this
  Bitkit build resolves profiles.
- No Pubky identity in Bitkit, and a cold launch, so no Ring row profile is remembered from earlier
  in the session.

Without Pubky Ring, run the steps as a manual test and name the missing capability in the PR.
Tapping a row signs in with that Ring identity, so use identities you are happy to adopt.

**Contact import after leaving.** The Ring setup above, with an identity that follows many pubkys
on pubky.app (62, as in [`import-all-contacts.xml`](../contacts/import-all-contacts.xml)), so the
import takes long enough to leave, and no Pubky identity in Bitkit. The journey saves the follows as
contacts; sign out in Bitkit before running it again.

**Contacts list loading.** A Pubky identity with at least five saved contacts, at least one with a
published profile name and bio and one with no published profile. Importing such follows with
[`import-all-contacts.xml`](../contacts/import-all-contacts.xml) leaves exactly that.

## Timing

Every loading state here can finish faster than a snapshot round trip on a warm network. Each
journey reports that ("already loaded", "already resolved", "already adopted" or "already imported")
rather than failing. The cached-header journey repeats the relaunch once, and the others continue.

A contact with no published profile is the slow case: its lookup can take several seconds to give
up, and before this change Contacts waited for every such lookup before showing any row. A contact
import saves only to the device, so it can finish before you leave it; the journey then reports
"already imported".

Opening Profile in the first few seconds after launch can show a bare spinner, with no "Profile"
title, before the cached header. That spinner is the Pubky initialization wait in `MainNavView`. The
cached header needs initialization to finish, so wait for it to clear and do not report it as the
header failing. A spinner under the "Profile" title with no name is different: it means no cached
header showed.

Contacts opened while the Pubky session is still restoring after a relaunch shows the Profile
loading screen first (`ProfileLoading` under the "Profile" title) and moves on to the list by itself
once the session is back. That is the session restore, not the contacts list, so wait for the list
rather than reporting the spinner.

## iOS vs Android

- **Profile while loading.** iOS shows the cached name and avatar read-only under
  `ProfileCachedHeader`, with no edit, copy, share, QR code or tag controls, and then the full
  profile under `ProfileViewName`.
- **Contact import after leaving and Contacts list.** `contact-import-after-leaving.xml` and
  `contacts-list-loading.xml` are new on both platforms at once: synonymdev/bitkit-android#1399 adds
  both to Android with the same file names, journey names and prose, changing only identifiers and
  `adb` commands, and adds `ContactImportOverviewImportAll`, the only contact import testTag the
  journeys use, so once it merges the two platforms share the journeys and that identifier. Android
  master has neither until then. On iOS, `ContactImportUITests` also leaves an import while its save
  is held, so that check does not depend on the import being slow.
  `Contact_<pubky>`, `HeaderMenu`, `DrawerContacts`, `PayContactsContinue`, `ContactViewNotes`,
  `ContactEdit`, `ProfileEditCancel` and `NavigationBack` already match Android. Android has no
  identifier for the overview profile and summary (`ContactImportOverviewProfile`,
  `ContactImportOverviewSummary`) and names the Ring rows differently; see
  [Identifiers](../README.md#identifiers).
- **Ring choice rows.** Android names the rows and their lookup spinners differently; see
  [Identifiers](../README.md#identifiers). iOS keeps the rows up, spins only the tapped row, and
  tags each row `PubkyChoiceRing_<pubky>`, using the bare z32 key without the `pubky` prefix.
  While a row's lookup runs, iOS shows a spinner in place of its avatar, tagged
  `PubkyChoiceRingLookup_<pubky>`. Adopting a row stops the other rows' lookups, so their spinners
  go, and the tapped row keeps its avatar.

## Identifiers used

- Home: the header profile button `ProfileButton`; Profile intro `ProfileIntro` with Continue
  `ProfileIntro-button`.
- Profile: cached header `ProfileCachedHeader` and its name `ProfileCachedName`; full profile name
  `ProfileViewName`; actions `ProfileEdit`, `ProfileCopy`, `ProfileShare`, `ProfileQRCode` and
  `ProfileAddTag`.
- Choice screen: Ring rows `PubkyChoiceRing_<pubky>`, a row's lookup spinner
  `PubkyChoiceRingLookup_<pubky>`, and the create option `PubkyChoiceCreate`.
- After adopting: the contact import overview `ContactImportOverviewProfile`, or Pay Contacts
  `PayContactsContinue`.
- Contact import: overview summary `ContactImportOverviewSummary`, Import All
  `ContactImportOverviewImportAll` and Back `NavigationBack`.
- Contacts: the menu button `HeaderMenu` and drawer item `DrawerContacts`; contact rows
  `Contact_<pubky>`, using the full key with its `pubky` prefix.
