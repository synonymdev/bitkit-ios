# Bitkit Pubky Auth companion claims

Bitkit can authorize a Pubky session and share Paykit access, a watch-only Bitcoin account, or both. The request explicitly selects the material to share; homeserver write permissions alone never imply key export.

Bitkit's own session includes the Paykit authorizer scope. On identity activation it publishes the identity-signed Noise key before advertising private Paykit capabilities. Sessions granted to other apps keep the normal Paykit scope; they cannot replace this authorization record.

## Request

- The Pubky Auth URL includes exactly one `x-bitkit-claim` parameter containing a dot-separated list of independent requested items:
  - `watch-only-account-v1`: a watch-only account.
  - `paykit-access-v1`: the generation-bound Paykit secret.
- Paykit Server requests both with `x-bitkit-claim=paykit-access-v1.watch-only-account-v1`. Either order is accepted; the exact value is retained for signing and relay-channel derivation.
- The capability is `/pub/paykit/:rw`.
- Empty, unknown, or duplicate items and duplicate companion-claim parameters are rejected. Ordinary Pubky Auth without a companion claim shares only the session.
- Watch-only approval creates a fresh native-SegWit account. New account indexes start at `1`, increase monotonically, and are never recycled. Retrying the same logical auth request reuses its incomplete account even if query parameters are reordered.
- Bitkit automatically names the account from the requesting service. The user can rename it later. The local name is not disclosed in the claim.
- Reconnecting requests only `paykit-access-v1`; the server retains its existing watch-only account and verifies the approving identity. Bitkit does not allocate or share an xpub for this request. The server rejects an unexpected replacement xpub or account index.
- Paykit-only approval neither allocates nor loads a Bitcoin account. Its approval screen explains access to private Paykit state and communication, without watch-only or content-earning UI.

## Claim payload

The watch-only payload is 84 bytes:

| Offset | Size | Value |
| --- | ---: | --- |
| 0 | 1 | Claim version, `0x01` |
| 1 | 4 | BIP account index, unsigned big-endian |
| 5 | 1 | Address type, `0x00` for native SegWit |
| 6 | 78 | Base58Check-decoded extended public key, including its 4-byte version |

The Paykit-only payload is 41 bytes: version `1`, 8-byte nonzero big-endian key generation, and 32-byte Paykit identity secret. When both items are requested, the payload is 124 bytes: the watch-only payload followed by that generation and secret, without a second version byte. Payload order does not depend on request-item order.

Bitkit passes the exact requested list as `claim_type` and only the requested material as the payload to Paykit's `approveAuthWithCompanionClaim` API. Paykit appends a 64-byte Ed25519 signature, encrypts the claim, delivers it in one companion relay response, and only then approves normal Pubky Auth.

For requests including Paykit access, Bitkit derives the Paykit secret from its local or shared-Keychain Pubky identity secret and the current App Registry generation. The recipient derives the separate Noise and shared-state encryption keys from it. Neither the Pubky root secret nor Bitcoin spending keys are shared. A delegated secret cannot derive another generation.

The signature input is the byte concatenation:

```text
UTF8("x-bitkit-claim|" || claim_type || "|")
|| SHA256(decoded_auth_request_secret)
|| unsigned_claim_bytes
```

`decoded_auth_request_secret` is the raw 32-byte value produced by base64url-no-pad decoding the URL's `secret` parameter, not UTF-8 text.

The server verifies the signature with the creator's Pubky Ed25519 public key from the authenticated session. Binding the signature to the request secret prevents a valid signed claim from being moved to a different request; possession of the relay secret alone is insufficient to substitute an attacker's xpub.

## Delivery and lifecycle

- The companion channel is `base_relay/{base64url_no_pad(BLAKE3(UTF8(claim_type || "|") || secret))}`.
- Paykit encrypts the signed claim with the auth request secret using XSalsa20-Poly1305 and delivers it before approving the Pubky grant. The SDK owns relay transport and cryptography.
- Bitkit persists the account before delivery and reuses the same account index and unsigned xpub payload when retrying an incomplete setup. Each attempt may create new encrypted relay messages; delivery is not guaranteed exactly once.
- For new watch-only accounts, Bitkit durably marks and loads the account as authorizing before calling Paykit. Successful approval marks it active and leaves tracking enabled. An initial preparation or companion-delivery failure returns it to pending and unloads it again. Reauthorization of an already active account does not change this state.
- Account registration and address revelation finish before authorization. LDK's periodic sync fetches transaction history; a full wallet sync is not a prerequisite for delivering the authorization.
- If Paykit reports that companion delivery succeeded but grant approval failed, Bitkit leaves the new account authorizing and tracked. The same conservative state is retained if local activation persistence fails after Paykit returns success. Retrying uses the same account and xpub payload; retry failures keep the account tracked so Bitkit does not lose visibility into addresses the server may already have derived.
- Disabling tracking unloads the account from LDK Node at runtime. It does not delete persisted wallet state, the xpub, or the server session.
- Enabled active or authorizing accounts are configured before LDK Node starts. Electrum full scans use a batch size of `100` and stop gap of `1000`.
- Bitkit pre-reveals external receive indexes `0...999` for each tracked account. LDK then maintains a rolling stop-gap window: the first address with transaction history must be at or below index `999`, and after activity at index `n`, the next active index must be at or below `n + 1000` so there are never `1000` consecutive inactive addresses.
- On startup and before app-driven sync, Bitkit reconciles persisted account state with LDK and restores the pre-revealed range. Accounts removed by a backup remain scheduled for unload until reconciliation succeeds, allowing transient failures to retry safely.
- Account metadata and monotonic allocation state are included in the existing encrypted wallet backup and use the same JSON field names on iOS and Android.
