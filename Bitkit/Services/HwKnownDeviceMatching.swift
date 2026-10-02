import Foundation

/// Decides which stored entry a fresh connect refreshes, and which entries it supersedes.
///
/// A passphrase wallet is a separate identity on the same physical device, so the transport id
/// alone no longer identifies an entry: matching by it would overwrite another identity or blend
/// two identities' xpubs into one record. Shared key material is the identity.
enum HwKnownDeviceMatching {
    /// The entry this connect refreshed: among the entries of this transport, the one whose xpubs
    /// overlap the freshly read set. Only an entry stored before any xpub was captured has no
    /// identity to conflict with and can be adopted instead. Anything else is a new identity.
    static func previous(
        in devices: [HwKnownDevice],
        deviceId: String,
        fetchedXpubs: [String: String]
    ) -> HwKnownDevice? {
        let candidates = devices.filter { $0.id == deviceId }
        let fetched = Set(fetchedXpubs.values)
        if let overlapping = candidates.first(where: { !Set($0.xpubs.values).isDisjoint(with: fetched) }) {
            return overlapping
        }
        guard candidates.count == 1, let only = candidates.first, only.xpubs.isEmpty else { return nil }
        return only
    }

    /// The entry a new record inherits its Bitkit-side label from. Labels are set for the wallet,
    /// not for the transport it happens to be reached over, so a wallet showing up on a new path
    /// keeps the name the user gave it instead of falling back to the device's own.
    static func named(
        in devices: [HwKnownDevice],
        previous: HwKnownDevice?,
        walletKey: String
    ) -> HwKnownDevice? {
        previous ?? devices.first { $0.walletKey == walletKey }
    }

    /// The stored list after `known` supersedes what it replaces.
    static func merged(
        _ devices: [HwKnownDevice],
        with known: HwKnownDevice,
        refreshed: HwKnownDevice?
    ) -> [HwKnownDevice] {
        devices.filter { !isReplaced($0, by: known, refreshed: refreshed) } + [known]
    }

    /// Whether a stored entry gives way to the one just read. That covers the identity it holds and
    /// the entry this connect refreshed, since reading a previously rejected address type changes
    /// the wallet key and matching on the new key alone would leave the old entry behind as a
    /// duplicate. Wallets of a seed the device no longer carries go too: nothing would ever
    /// supersede them by key material. An unknown device id proves nothing, so those are left alone,
    /// and so is every entry of another vendor, even one holding the same seed.
    private static func isReplaced(
        _ entry: HwKnownDevice,
        by known: HwKnownDevice,
        refreshed: HwKnownDevice?
    ) -> Bool {
        guard entry.vendor == known.vendor, entry.id == known.id else { return false }
        if entry.walletKey == known.walletKey {
            return true
        }
        if let refreshed, entry.walletKey == refreshed.walletKey {
            return true
        }
        guard let knownHardwareId = known.hardwareId, let entryHardwareId = entry.hardwareId else { return false }
        return entryHardwareId != knownHardwareId
    }
}
