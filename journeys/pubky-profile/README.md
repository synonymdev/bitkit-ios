# Pubky profile loading

This suite covers what Profile and the Pubky Ring choice screen show while their profiles are still
loading from the network. Where Android differs, see [iOS vs Android](#ios-vs-android).

- `cached-profile-header.xml` opens Profile straight after a relaunch, while the signed-in profile is
  still loading. Profile shows the name cached from the last load, read-only, then swaps in the full
  profile in place.
- `ring-choice-rows.xml` opens the choice screen with Pubky Ring identities. The rows show straight
  away under truncated keys and fill in names as each lookup finishes. While a row's lookup runs, a
  spinner stands in for its avatar, so a row still looking up does not look like a row whose
  identity has no profile. A lookup for an identity with no profile can take several seconds to give
  up. Tapping a row adopts that identity: only the tapped row shows a spinner, and every row is
  disabled until adoption finishes.

## Preconditions

Both journeys need an onboarded E2E Bitkit build with Paykit UI enabled. Use the test simulator UDID
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

## Timing

Both loading states can finish faster than a snapshot round trip on a warm network. Each journey
reports that ("already loaded", "already resolved" or "already adopted") rather than failing. The
cached-header journey repeats the relaunch once, and the ring journey continues.

Opening Profile in the first few seconds after launch can show a bare spinner, with no "Profile"
title, before the cached header. That spinner is the Pubky initialization wait in `MainNavView`. The
cached header needs initialization to finish, so wait for it to clear and do not report it as the
header failing. A spinner under the "Profile" title with no name is different: it means no cached
header showed.

## iOS vs Android

- **Profile while loading.** Android shows only a spinner until the profile loads. iOS shows the
  cached name and avatar read-only under `ProfileCachedHeader`, with no edit, copy, share, QR code
  or tag controls, and then the full profile under `ProfileViewName`.
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
