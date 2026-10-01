# Pubky profile loading

This suite covers what Profile, the Pubky Ring choice screen, the contact import and Contacts show
while profiles are still loading from the network. Where Android differs, see
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
- `contact-import.xml` adopts a Ring identity that follows other pubkys and imports its follows with
  Import All. The import saves the profiles the overview already looked up instead of looking every
  follow up again, so it takes seconds rather than tens of seconds. A follow with no published
  profile is imported under its truncated key. While the import runs, Select and Import All are
  disabled. Leaving the screen does not stop the import, and an import that finishes after you left
  does not take you to Pay Contacts.
- `contacts-list-loading.xml` relaunches and opens Contacts. The saved contacts show straight away
  under the names they were saved with, and each fills in its profile name and avatar as its lookup
  finishes. Reopening Contacts in the same session shows the profiles already found straight away.
  Opening a contact whose profile has not loaded yet looks it up at once, and its edit form shows
  the published bio.

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

**Contact import.** The Ring setup above, with an identity that follows at least five pubkys on
pubky.app, at least one of them with no published profile, and no Pubky identity in Bitkit. The
journey saves the follows as contacts; sign out in Bitkit before running it again.

**Contacts list loading.** A Pubky identity with at least five saved contacts, at least one with a
published profile name and bio and one with no published profile. Running the contact import journey
first leaves exactly that if one of the follows publishes a bio.

## Timing

Every loading state here can finish faster than a snapshot round trip on a warm network. Each
journey reports that ("already loaded", "already resolved", "already adopted" or "already imported")
rather than failing. The cached-header journey repeats the relaunch once, and the others continue.

A follow or contact with no published profile is the slow case: its lookup can take several seconds
to give up, and before this change the import and Contacts both waited for every such lookup.

Opening Profile in the first few seconds after launch can show a bare spinner, with no "Profile"
title, before the cached header. That spinner is the Pubky initialization wait in `MainNavView`. The
cached header needs initialization to finish, so wait for it to clear and do not report it as the
header failing. A spinner under the "Profile" title with no name is different: it means no cached
header showed.

## iOS vs Android

- **Profile while loading.** iOS shows the cached name and avatar read-only under
  `ProfileCachedHeader`, with no edit, copy, share, QR code or tag controls, and then the full
  profile under `ProfileViewName`.
- **Contact import and Contacts list.** These two journeys are new on iOS. The import overview,
  selection and Contacts identifiers already match Android (`ContactImportOverviewSelect`,
  `ContactImportOverviewImportAll`, `ContactImportSelectContinue`, `Contact_<pubky>`). iOS has always
  kept a follow with no published profile in the import; it shows under its truncated key.
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
- Contact import: overview summary `ContactImportOverviewSummary`, Select `ContactImportOverviewSelect`
  and Import All `ContactImportOverviewImportAll`; selection rows `ContactImportSelect_<pubky>` and
  Continue `ContactImportSelectContinue`.
- Contacts: the menu button `HeaderMenu` and drawer item `DrawerContacts`; contact rows
  `Contact_<pubky>`, using the full key with its `pubky` prefix.
