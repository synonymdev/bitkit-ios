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
    static let legacyPublicAddressesKey = "publicPaykitLegacyAddresses"

    struct AddressOperations {
        var next: (LDKNode.AddressType) async throws -> LightningService.AddressDerivationInfo
        var resolve: (LDKNode.AddressType, UInt32) async throws -> String
        var reveal: (LDKNode.AddressType, UInt32) async throws -> Void
        var isUsed: (String) async throws -> Bool

        static let live = AddressOperations(
            next: { try await LightningService.shared.newAddressInfoForType($0) },
            resolve: { try await LightningService.shared.addressInfoForType($0, atIndex: $1).address },
            reveal: { try await LightningService.shared.revealReceiveAddresses(to: $1, forType: $0) },
            isUsed: { try await CoreService.shared.utility.isAddressUsed(address: $0) }
        )
    }

    private let defaults: UserDefaults
    private let operations: AddressOperations
    private(set) var attributionRevision: UInt64 = 0
    private var ledger: Ledger {
        didSet { attributionRevision &+= 1 }
    }

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard, operations: AddressOperations = .live) {
        self.defaults = defaults
        self.operations = operations

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

    func legacyPublicAddressesSnapshot() -> [String]? {
        let addresses = defaults.stringArray(forKey: Self.legacyPublicAddressesKey) ?? []
        return addresses.isEmpty ? nil : addresses
    }

    func restoreBackup(_ highestReservedReceiveIndexByAddressType: [String: UInt32]?, legacyPublicAddresses: [String]? = nil) {
        let legacyAddresses = Set(legacyPublicAddressesSnapshot() ?? []).union(legacyPublicAddresses ?? [])
        defaults.set(legacyAddresses.sorted(), forKey: Self.legacyPublicAddressesKey)
        var ceilings = self.highestReservedReceiveIndexByAddressType()
        for (addressType, ceiling) in highestReservedReceiveIndexByAddressType ?? [:] {
            ceilings[addressType] = max(ceilings[addressType] ?? 0, ceiling)
        }

        // An older backup cannot release addresses that this wallet already exposed.
        ledger = Ledger(
            version: Self.schemaVersion,
            reservedReceiveIndexesByAddressType: [:],
            contactAssignments: [:],
            contactAssignmentHistory: [:],
            restoredReservedReceiveIndexCeilingsByAddressType: ceilings
        )
        persist()

        if !ceilings.isEmpty || !legacyAddresses.isEmpty {
            defaults.removeObject(forKey: "onchainAddress")
        }
    }

    private static func decodeStoredLedger(_ data: Data) -> Ledger? {
        try? JSONDecoder().decode(Ledger.self, from: data)
    }

    // MARK: - Contact Assignments

    func contactPublicKey(forReservedAddress address: String) async -> String? {
        try? await contactPublicKeyForAttribution(forReservedAddress: address)
    }

    func contactPublicKeyForAttribution(forReservedAddress address: String) async throws -> String? {
        guard !address.isEmpty else { return nil }
        for (publicKey, assignment) in contactAssignmentsForAttribution() {
            guard let addressType = LDKNode.AddressType.from(string: assignment.addressType),
                  addressType.matchesAddressFormat(address, network: Env.network)
            else { continue }
            if try await self.address(for: addressType, receiveIndex: assignment.receiveIndex) == address {
                return publicKey
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

            return assignmentKey
        }

        return nil
    }

    func currentOrRotatedAddress(for publicKey: String) async throws -> String {
        let assignmentKey = try Self.normalizedPublicKey(publicKey)
        if let existing = try await reservedAddressDetails(forAssignmentKey: assignmentKey) {
            guard isAddressTypeMonitored(existing.addressType) else {
                clearCurrentContactAssignment(assignmentKey: assignmentKey)
                return try await allocateAddress(forAssignmentKey: assignmentKey)
            }

            do {
                let isUsed = try await operations.isUsed(existing.address)
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

    func currentOrRotatedPublicAddress(for publicKey: String) async throws -> String {
        let key = try Self.normalizedPublicKey(publicKey)
        if let assignment = ledger.publicAssignments?[key],
           let addressType = LDKNode.AddressType.from(string: assignment.addressType),
           isAddressTypeMonitored(addressType)
        {
            let address = try await address(for: addressType, receiveIndex: assignment.receiveIndex)
            if try await !operations.isUsed(address) {
                return address
            }
        }

        let addressType = LDKNode.AddressType.fromStorage(defaults.string(forKey: "selectedAddressType"))
        let receiveAddress = reusableOnchainAddress
        try await prepareReusableReceive(addressType: addressType)
        var info = try await nextAvailableAddressInfo(addressType: addressType)
        if info.address == receiveAddress || info.address == reusableOnchainAddress {
            try await reconcileAddressTypeWithLdk(addressType, highestReserved: info.index)
            let previousIndex = info.index
            info = try await nextAvailableAddressInfo(addressType: addressType)
            guard info.index > previousIndex, info.address != receiveAddress, info.address != reusableOnchainAddress else {
                throw AppError(message: "Unable to reserve public payment address", debugMessage: nil)
            }
        }
        try Task.checkCancellation()
        reserve(info.index, addressType: addressType)
        var assignments = ledger.publicAssignments ?? [:]
        assignments[key] = StoredAssignment(addressType: addressType.stringValue, receiveIndex: info.index)
        ledger.publicAssignments = assignments
        persist()
        markWalletBackupDataChanged()
        return info.address
    }

    func isCurrentPublicAddressUsed(for publicKey: String) async throws -> Bool {
        let key = try Self.normalizedPublicKey(publicKey)
        guard let assignment = ledger.publicAssignments?[key],
              let addressType = LDKNode.AddressType.from(string: assignment.addressType)
        else { return false }
        let address = try await address(for: addressType, receiveIndex: assignment.receiveIndex)
        return try await operations.isUsed(address)
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
            assignments.append((publicKey: assignmentKey, assignment: assignment))
        }

        for (assignmentKey, history) in ledger.contactAssignmentHistory {
            for assignment in history {
                let key = Self.assignmentKey(assignment)
                guard seenAssignmentKeys.insert(key).inserted else { continue }
                assignments.append((publicKey: assignmentKey, assignment: assignment))
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
                if try await operations.isUsed(address) {
                    publicKeys.append(assignmentKey)
                }
            } catch {
                Logger.warn(
                    "Unable to check private Paykit reserved address usage for \(PubkyPublicKeyFormat.redacted(assignmentKey)): \(error)",
                    context: "PrivatePaykit"
                )
            }
        }

        return Array(Set(publicKeys)).sorted()
    }

    // MARK: - Reusable Receive Protection

    func reconcileReservedIndexesWithLdk() async {
        for (addressTypeString, highestReserved) in highestReservedReceiveIndexByAddressType() {
            guard let addressType = LDKNode.AddressType.from(string: addressTypeString), isAddressTypeMonitored(addressType) else { continue }

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

        let addressInfo = try await nextAvailableAddressInfo(addressType: addressType)
        return addressInfo.address
    }

    func isUnavailableForReusableReceive(address: String, addressType: LDKNode.AddressType) async -> Bool {
        if legacyPublicAddressesSnapshot()?.contains(address) == true {
            return true
        }
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
        if legacyPublicAddressesSnapshot()?.contains(address) == true {
            return true
        }

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
        defaults.removeObject(forKey: Self.legacyPublicAddressesKey)
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
        clearContactAssignments(publicKeys: [publicKey])
    }

    func clearContactAssignments(publicKeys: [String]) {
        let normalizedKeys = Set(publicKeys.compactMap(PubkyPublicKeyFormat.normalized))

        let previousCount = ledger.contactAssignments.count
        let previousHistoryCount = ledger.contactAssignmentHistory.count
        ledger.contactAssignments = ledger.contactAssignments.filter { !normalizedKeys.contains($0.key) }
        ledger.contactAssignmentHistory = ledger.contactAssignmentHistory.filter { !normalizedKeys.contains($0.key) }
        let removedCurrent = ledger.contactAssignments.count != previousCount
        let removedHistory = ledger.contactAssignmentHistory.count != previousHistoryCount
        guard removedCurrent || removedHistory else { return }

        persist()
    }

    func clearContactAssignments(excludingPublicKeys publicKeys: [String]) {
        let normalizedKeys = Set(publicKeys.compactMap(PubkyPublicKeyFormat.normalized))
        let previousCount = ledger.contactAssignments.count
        let previousHistoryCount = ledger.contactAssignmentHistory.count
        ledger.contactAssignments = ledger.contactAssignments.filter { normalizedKeys.contains($0.key) }
        ledger.contactAssignmentHistory = ledger.contactAssignmentHistory
            .filter { normalizedKeys.contains($0.key) }
        guard ledger.contactAssignments.count != previousCount || ledger.contactAssignmentHistory.count != previousHistoryCount else { return }

        persist()
    }

    private func clearCurrentContactAssignment(assignmentKey: String) {
        guard ledger.contactAssignments.removeValue(forKey: assignmentKey) != nil else { return }

        persist()
    }

    // MARK: - Private Address Allocation

    private func allocateAddress(forAssignmentKey assignmentKey: String) async throws -> String {
        let addressType = LDKNode.AddressType.fromStorage(defaults.string(forKey: "selectedAddressType"))
        let addressTypeKey = addressType.stringValue

        try await prepareReusableReceive(addressType: addressType)

        let addressInfo = try await nextAvailableAddressInfo(addressType: addressType)

        reserve(addressInfo.index, addressType: addressType)

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

    private func reserve(_ index: UInt32, addressType: LDKNode.AddressType) {
        ledger.reservedReceiveIndexesByAddressType[addressType.stringValue, default: []].insert(index)
    }

    private func nextAvailableAddressInfo(addressType: LDKNode.AddressType) async throws -> LightningService.AddressDerivationInfo {
        var info = try await operations.next(addressType)
        while legacyPublicAddressesSnapshot()?.contains(info.address) == true {
            reserve(info.index, addressType: addressType)
            persist()
            markWalletBackupDataChanged()
            try await reconcileAddressTypeWithLdk(addressType, highestReserved: info.index)
            let previousIndex = info.index
            info = try await operations.next(addressType)
            guard info.index > previousIndex else { throw AppError(message: "Unable to advance reserved payment address", debugMessage: nil) }
        }
        guard !isUnavailableForReusableReceive(receiveIndex: info.index, addressType: addressType) else {
            throw AppError(message: "Unable to allocate reserved payment address", debugMessage: nil)
        }
        return info
    }

    private func rememberContactAssignmentForAttribution(assignmentKey: String, assignment: StoredAssignment) {
        var history = ledger.contactAssignmentHistory[assignmentKey] ?? []
        guard !history.contains(assignment) else { return }

        history.append(assignment)
        ledger.contactAssignmentHistory[assignmentKey] = history
    }

    // MARK: - LDK Address Index APIs

    private func reconcileAddressTypeWithLdk(_ addressType: LDKNode.AddressType, highestReserved: UInt32) async throws {
        try await operations.reveal(addressType, highestReserved)
    }

    private func address(for addressType: LDKNode.AddressType, receiveIndex: UInt32) async throws -> String {
        try await operations.resolve(addressType, receiveIndex)
    }

    private static func assignmentKey(_ assignment: StoredAssignment) -> String {
        "\(assignment.addressType):\(assignment.receiveIndex)"
    }

    private static func normalizedPublicKey(_ publicKey: String) throws -> String {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            throw PrivatePaykitError.privateUnavailable
        }
        return normalizedKey
    }

    // MARK: - Cached Receive Address

    private var reusableOnchainAddress: String {
        defaults.string(forKey: "onchainAddress") ?? ""
    }

    private func ensureReusableOnchainAddress(afterReserving reservedAddress: String, addressType: LDKNode.AddressType) async {
        let currentAddress = reusableOnchainAddress
        let currentIsUnavailable = await isUnavailableForReusableReceive(address: currentAddress)
        if !currentAddress.isEmpty, currentAddress != reservedAddress, !currentIsUnavailable {
            return
        }

        do {
            let replacement = try await nextNonReservedReceiveAddress(addressType: addressType)
            defaults.set(replacement, forKey: "onchainAddress")
        } catch {
            defaults.set("", forKey: "onchainAddress")
            Logger.warn("Failed to refresh reusable receive address after private Paykit reservation: \(error)", context: "PrivatePaykit")
        }
    }

    private func clearReusableOnchainAddressIfReserved() async {
        let reusableAddress = reusableOnchainAddress
        guard !reusableAddress.isEmpty else { return }

        if await isUnavailableForReusableReceive(address: reusableAddress) {
            defaults.set("", forKey: "onchainAddress")
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
        var publicAssignments: [String: StoredAssignment]?
    }

    private struct StoredAssignment: Codable, Equatable {
        var addressType: String
        var receiveIndex: UInt32
    }
}
