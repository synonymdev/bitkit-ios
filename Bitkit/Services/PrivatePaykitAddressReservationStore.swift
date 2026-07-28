import Combine
import Foundation
import LDKNode

actor PrivatePaykitAddressReservationStore {
    static let shared = PrivatePaykitAddressReservationStore()

    private static let walletBackupDataChangedSubject = PassthroughSubject<Void, Never>()

    nonisolated static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        walletBackupDataChangedSubject.eraseToAnyPublisher()
    }

    private static let defaultsKey = "privatePaykitAddressReservations"
    private static let schemaVersion = 1

    private let defaults: UserDefaults
    private var ledger: Ledger

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = Self.decodeStoredLedger(data)
        {
            ledger = decoded
        } else {
            ledger = .empty
        }
    }

    // MARK: - Backup

    func backupSnapshot() -> [String: UInt32]? {
        let highestReservedReceiveIndexByAddressType = highestReservedReceiveIndexByAddressType()
        guard !highestReservedReceiveIndexByAddressType.isEmpty else {
            return nil
        }

        return highestReservedReceiveIndexByAddressType
    }

    func restoreBackup(_ highestReservedReceiveIndexByAddressType: [String: UInt32]?) {
        guard let highestReservedReceiveIndexByAddressType else {
            ledger = .empty
            persist()
            return
        }

        ledger = Ledger(
            version: Self.schemaVersion,
            reservedReceiveIndexesByAddressType: [:],
            contactAssignments: [:],
            contactAssignmentHistory: [:],
            restoredReservedReceiveIndexCeilingsByAddressType: highestReservedReceiveIndexByAddressType
        )
        persist()

        if !highestReservedReceiveIndexByAddressType.isEmpty {
            UserDefaults.standard.removeObject(forKey: "onchainAddress")
        }
    }

    private static func decodeStoredLedger(_ data: Data) -> Ledger? {
        try? JSONDecoder().decode(Ledger.self, from: data)
    }

    // MARK: - Contact Assignments

    func contactPublicKey(forReservedAddress address: String) async -> String? {
        guard !address.isEmpty else { return nil }

        if let publicKey = await currentContactPublicKey(forReservedAddress: address) {
            return publicKey
        }

        for (assignmentKey, history) in ledger.contactAssignmentHistory {
            for assignment in history {
                guard let addressType = LDKNode.AddressType.from(string: assignment.addressType),
                      addressType.matchesAddressFormat(address, network: Env.network),
                      let reservedAddress = try? await self.address(for: addressType, receiveIndex: assignment.receiveIndex),
                      reservedAddress == address
                else { continue }

                return Self.publicKey(fromAssignmentKey: assignmentKey)
            }
        }

        return nil
    }

    func currentContactPublicKey(forReservedAddress address: String) async -> String? {
        guard !address.isEmpty else { return nil }

        for (assignmentKey, assignment) in ledger.contactAssignments {
            guard let addressType = LDKNode.AddressType.from(string: assignment.addressType),
                  addressType.matchesAddressFormat(address, network: Env.network),
                  let reservedAddress = try? await self.address(for: addressType, receiveIndex: assignment.receiveIndex),
                  reservedAddress == address
            else { continue }

            return Self.publicKey(fromAssignmentKey: assignmentKey)
        }

        return nil
    }

    func currentOrRotatedAddress(for publicKey: String, receiverPath: String) async throws -> String {
        let assignmentKey = try Self.contactAssignmentKey(publicKey: publicKey, receiverPath: receiverPath)
        if let existing = try await reservedAddressDetails(forAssignmentKey: assignmentKey) {
            guard isAddressTypeMonitored(existing.addressType) else {
                clearCurrentContactAssignment(assignmentKey: assignmentKey)
                return try await allocateAddress(forAssignmentKey: assignmentKey)
            }

            do {
                let isUsed = try await CoreService.shared.utility.isAddressUsed(address: existing.address)
                if !isUsed {
                    return existing.address
                }
            } catch {
                Logger.warn(
                    "Unable to verify private Paykit address usage; skipping private address publication: \(error)",
                    context: "PrivatePaykit"
                )
                throw error
            }
        }

        return try await allocateAddress(forAssignmentKey: assignmentKey)
    }

    private func reservedAddressDetails(forAssignmentKey assignmentKey: String) async throws -> (address: String, addressType: LDKNode.AddressType)? {
        guard let assignment = ledger.contactAssignments[assignmentKey],
              let addressType = LDKNode.AddressType.from(string: assignment.addressType)
        else { return nil }

        let address = try await address(for: addressType, receiveIndex: assignment.receiveIndex)
        return (address: address, addressType: addressType)
    }

    private func highestReservedReceiveIndexByAddressType() -> [String: UInt32] {
        var highest = ledger.reservedReceiveIndexesByAddressType.compactMapValues { $0.max() }
        for (addressType, ceiling) in ledger.restoredReservedReceiveIndexCeilingsByAddressType {
            highest[addressType] = max(highest[addressType] ?? 0, ceiling)
        }
        return highest
    }

    private func contactAssignmentsForAttribution() -> [(publicKey: String, assignment: StoredAssignment)] {
        var seenAssignmentKeys = Set<String>()
        var assignments: [(publicKey: String, assignment: StoredAssignment)] = []

        for (assignmentKey, assignment) in ledger.contactAssignments {
            let key = Self.assignmentKey(assignment)
            guard seenAssignmentKeys.insert(key).inserted else { continue }
            assignments.append((publicKey: Self.publicKey(fromAssignmentKey: assignmentKey), assignment: assignment))
        }

        for (assignmentKey, history) in ledger.contactAssignmentHistory {
            for assignment in history {
                let key = Self.assignmentKey(assignment)
                guard seenAssignmentKeys.insert(key).inserted else { continue }
                assignments.append((publicKey: Self.publicKey(fromAssignmentKey: assignmentKey), assignment: assignment))
            }
        }

        return assignments
    }

    // MARK: - Rotation Detection

    func contactsWithUsedReservedAddresses() async -> [String] {
        var publicKeys: [String] = []

        for (assignmentKey, assignment) in ledger.contactAssignments {
            guard let addressType = LDKNode.AddressType.from(string: assignment.addressType),
                  let address = try? await address(for: addressType, receiveIndex: assignment.receiveIndex)
            else { continue }

            do {
                if try await CoreService.shared.utility.isAddressUsed(address: address) {
                    publicKeys.append(Self.publicKey(fromAssignmentKey: assignmentKey))
                }
            } catch {
                Logger.warn(
                    "Unable to check private Paykit reserved address usage for \(PubkyPublicKeyFormat.redacted(Self.publicKey(fromAssignmentKey: assignmentKey))): \(error)",
                    context: "PrivatePaykit"
                )
            }
        }

        return Array(Set(publicKeys)).sorted()
    }

    // MARK: - Reusable Receive Protection

    func reconcileReservedIndexesWithLdk() async {
        for (addressTypeString, highestReserved) in highestReservedReceiveIndexByAddressType() {
            guard let addressType = LDKNode.AddressType.from(string: addressTypeString) else { continue }
            guard isAddressTypeMonitored(addressType) else { continue }

            do {
                try await reconcileAddressTypeWithLdk(addressType, highestReserved: highestReserved)
            } catch {
                Logger.warn("Failed to reconcile private Paykit address reservations: \(error)", context: "PrivatePaykit")
            }
        }

        await clearReusableOnchainAddressIfReserved()
    }

    func nextNonReservedReceiveAddress(addressType: LDKNode.AddressType) async throws -> String {
        try await prepareReusableReceive(addressType: addressType)

        let addressInfo = try await LightningService.shared.newAddressInfoForType(addressType)
        guard !isUnavailableForReusableReceive(receiveIndex: addressInfo.index, addressType: addressType) else {
            throw AppError(
                message: "Unable to generate receive address",
                debugMessage: "LDK returned unavailable receive index \(addressInfo.index) after reservation reconciliation"
            )
        }

        return addressInfo.address
    }

    func isUnavailableForReusableReceive(address: String, addressType: LDKNode.AddressType) async -> Bool {
        guard !address.isEmpty,
              addressType.matchesAddressFormat(address, network: Env.network)
        else { return false }

        let addressTypeKey = addressType.stringValue
        for receiveIndex in ledger.reservedReceiveIndexesByAddressType[addressTypeKey] ?? [] {
            guard let reservedAddress = try? await self.address(for: addressType, receiveIndex: receiveIndex),
                  reservedAddress == address
            else { continue }

            return true
        }

        return false
    }

    func isUnavailableForReusableReceive(address: String) async -> Bool {
        guard !address.isEmpty else { return false }

        for addressTypeString in highestReservedReceiveIndexByAddressType().keys {
            guard let addressType = LDKNode.AddressType.from(string: addressTypeString),
                  await isUnavailableForReusableReceive(address: address, addressType: addressType)
            else { continue }

            return true
        }

        return false
    }

    private func prepareReusableReceive(addressType: LDKNode.AddressType) async throws {
        if let highestReserved = highestReservedReceiveIndexByAddressType()[addressType.stringValue] {
            try await reconcileAddressTypeWithLdk(addressType, highestReserved: highestReserved)
        }

        await clearReusableOnchainAddressIfReserved()
    }

    private func isUnavailableForReusableReceive(receiveIndex: UInt32, addressType: LDKNode.AddressType) -> Bool {
        let addressTypeKey = addressType.stringValue
        let reservedIndexes = ledger.reservedReceiveIndexesByAddressType[addressTypeKey] ?? []
        if reservedIndexes.contains(receiveIndex) {
            return true
        }

        if let restoredCeiling = ledger.restoredReservedReceiveIndexCeilingsByAddressType[addressTypeKey],
           receiveIndex <= restoredCeiling
        {
            return true
        }

        return false
    }

    // MARK: - Cleanup

    func clear() {
        ledger = .empty
        defaults.removeObject(forKey: Self.defaultsKey)
        markWalletBackupDataChanged()
    }

    func clearContactAssignments() {
        guard !ledger.contactAssignments.isEmpty || !ledger.contactAssignmentHistory.isEmpty else { return }
        ledger.contactAssignments = [:]
        ledger.contactAssignmentHistory = [:]
        persist()
    }

    func clearContactAssignment(publicKey: String) {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }

        let previousCount = ledger.contactAssignments.count
        let previousHistoryCount = ledger.contactAssignmentHistory.count
        ledger.contactAssignments = ledger.contactAssignments.filter { Self.publicKey(fromAssignmentKey: $0.key) != normalizedKey }
        ledger.contactAssignmentHistory = ledger.contactAssignmentHistory.filter { Self.publicKey(fromAssignmentKey: $0.key) != normalizedKey }
        let removedCurrent = ledger.contactAssignments.count != previousCount
        let removedHistory = ledger.contactAssignmentHistory.count != previousHistoryCount
        guard removedCurrent || removedHistory else { return }

        persist()
    }

    func clearContactAssignments(excludingPublicKeys publicKeys: [String]) {
        let normalizedKeys = Set(publicKeys.compactMap(PubkyPublicKeyFormat.normalized))
        let previousCount = ledger.contactAssignments.count
        let previousHistoryCount = ledger.contactAssignmentHistory.count
        ledger.contactAssignments = ledger.contactAssignments.filter { normalizedKeys.contains(Self.publicKey(fromAssignmentKey: $0.key)) }
        ledger.contactAssignmentHistory = ledger.contactAssignmentHistory
            .filter { normalizedKeys.contains(Self.publicKey(fromAssignmentKey: $0.key)) }
        guard ledger.contactAssignments.count != previousCount || ledger.contactAssignmentHistory.count != previousHistoryCount else { return }

        persist()
    }

    private func clearCurrentContactAssignment(assignmentKey: String) {
        guard ledger.contactAssignments.removeValue(forKey: assignmentKey) != nil else { return }

        persist()
    }

    // MARK: - Private Address Allocation

    private func allocateAddress(forAssignmentKey assignmentKey: String) async throws -> String {
        let addressType = LDKNode.AddressType.fromStorage(UserDefaults.standard.string(forKey: "selectedAddressType"))
        let addressTypeKey = addressType.stringValue

        try await prepareReusableReceive(addressType: addressType)

        let addressInfo = try await LightningService.shared.newAddressInfoForType(addressType)
        guard !isUnavailableForReusableReceive(receiveIndex: addressInfo.index, addressType: addressType) else {
            throw AppError(
                message: "Unable to reserve private Paykit address",
                debugMessage: "LDK returned unavailable receive index \(addressInfo.index) after reservation reconciliation"
            )
        }

        var reserved = ledger.reservedReceiveIndexesByAddressType[addressTypeKey] ?? []
        reserved.insert(addressInfo.index)
        ledger.reservedReceiveIndexesByAddressType[addressTypeKey] = reserved

        let assignment = StoredAssignment(
            addressType: addressTypeKey,
            receiveIndex: addressInfo.index
        )
        ledger.contactAssignments[assignmentKey] = assignment
        rememberContactAssignmentForAttribution(assignmentKey: assignmentKey, assignment: assignment)
        persist()
        markWalletBackupDataChanged()
        await ensureReusableOnchainAddress(afterReserving: addressInfo.address, addressType: addressType)

        return addressInfo.address
    }

    private func rememberContactAssignmentForAttribution(assignmentKey: String, assignment: StoredAssignment) {
        var history = ledger.contactAssignmentHistory[assignmentKey] ?? []
        guard !history.contains(assignment) else { return }

        history.append(assignment)
        ledger.contactAssignmentHistory[assignmentKey] = history
    }

    // MARK: - LDK Address Index APIs

    private func reconcileAddressTypeWithLdk(_ addressType: LDKNode.AddressType, highestReserved: UInt32) async throws {
        try await LightningService.shared.revealReceiveAddresses(to: highestReserved, forType: addressType)
    }

    private func address(for addressType: LDKNode.AddressType, receiveIndex: UInt32) async throws -> String {
        let addressInfo = try await LightningService.shared.addressInfoForType(addressType, atIndex: receiveIndex)
        return addressInfo.address
    }

    private static func assignmentKey(_ assignment: StoredAssignment) -> String {
        "\(assignment.addressType):\(assignment.receiveIndex)"
    }

    private static func contactAssignmentKey(publicKey: String, receiverPath: String) throws -> String {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            throw PrivatePaykitError.privateUnavailable
        }
        guard receiverPath != PaykitReceiverPath.wallet else {
            return normalizedKey
        }
        return "\(normalizedKey)#\(receiverPath)"
    }

    private static func publicKey(fromAssignmentKey assignmentKey: String) -> String {
        assignmentKey.components(separatedBy: "#").first ?? assignmentKey
    }

    // MARK: - Cached Receive Address

    private var reusableOnchainAddress: String {
        UserDefaults.standard.string(forKey: "onchainAddress") ?? ""
    }

    private func ensureReusableOnchainAddress(afterReserving reservedAddress: String, addressType: LDKNode.AddressType) async {
        let currentAddress = reusableOnchainAddress
        let currentIsUnavailable = await isUnavailableForReusableReceive(address: currentAddress)
        if !currentAddress.isEmpty, currentAddress != reservedAddress, !currentIsUnavailable {
            return
        }

        do {
            let replacement = try await nextNonReservedReceiveAddress(addressType: addressType)
            UserDefaults.standard.set(replacement, forKey: "onchainAddress")
        } catch {
            UserDefaults.standard.set("", forKey: "onchainAddress")
            Logger.warn("Failed to refresh reusable receive address after private Paykit reservation: \(error)", context: "PrivatePaykit")
        }
    }

    private func clearReusableOnchainAddressIfReserved() async {
        let reusableAddress = reusableOnchainAddress
        guard !reusableAddress.isEmpty else { return }

        if await isUnavailableForReusableReceive(address: reusableAddress) {
            UserDefaults.standard.set("", forKey: "onchainAddress")
        }
    }

    // MARK: - Address Type Monitoring

    private func isAddressTypeMonitored(_ addressType: LDKNode.AddressType) -> Bool {
        let state = LightningService.addressTypeStateFromUserDefaults(defaults)
        return addressType == state.selectedType || state.monitoredTypes.contains(addressType)
    }

    // MARK: - Persistence

    private func persist() {
        Self.persist(ledger: ledger, defaults: defaults)
    }

    private static func persist(ledger: Ledger, defaults: UserDefaults) {
        do {
            let encoded = try JSONEncoder().encode(ledger)
            defaults.set(encoded, forKey: Self.defaultsKey)
        } catch {
            Logger.error("Failed to persist private Paykit reservation ledger: \(error)", context: "PrivatePaykit")
        }
    }

    private func markWalletBackupDataChanged() {
        Self.walletBackupDataChangedSubject.send()
    }

    // MARK: - Models

    private struct Ledger: Codable {
        static let empty = Ledger(
            version: PrivatePaykitAddressReservationStore.schemaVersion,
            reservedReceiveIndexesByAddressType: [:],
            contactAssignments: [:],
            contactAssignmentHistory: [:],
            restoredReservedReceiveIndexCeilingsByAddressType: [:]
        )

        var version: Int
        var reservedReceiveIndexesByAddressType: [String: Set<UInt32>]
        var contactAssignments: [String: StoredAssignment]
        var contactAssignmentHistory: [String: [StoredAssignment]]
        var restoredReservedReceiveIndexCeilingsByAddressType: [String: UInt32]
    }

    private struct StoredAssignment: Codable, Equatable {
        var addressType: String
        var receiveIndex: UInt32
    }
}
