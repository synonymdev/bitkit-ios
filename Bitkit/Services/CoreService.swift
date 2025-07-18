import BitkitCore
import Foundation
import LDKNode

// MARK: - Activity Service

class ActivityService {
    private let coreService: CoreService
    
    // Track replacement transactions (RBF) to mark them as boosted
    private static var replacementTransactions: Set<String> = []
    
    // Track replaced transactions that should be ignored during sync
    private static var replacedTransactions: Set<String> = []

    init(coreService: CoreService) {
        self.coreService = coreService
    }

    func removeAll() async throws {
        try await ServiceQueue.background(.core) {
            // Only allow removing on regtest for now
            guard Env.network == .regtest else {
                throw AppError(message: "Regtest only", debugMessage: nil)
            }

            // Get all activities and delete them one by one
            let activities = try getActivities(
                filter: .all, txType: nil, tags: nil, search: nil, minDate: nil, maxDate: nil, limit: nil, sortDirection: nil)
            for activity in activities {
                let id: String
                switch activity {
                case .lightning(let ln): id = ln.id
                case .onchain(let on): id = on.id
                }

                _ = try deleteActivityById(activityId: id)
            }
        }
    }

    func insert(_ activity: Activity) async throws {
        try await ServiceQueue.background(.core) {
            try insertActivity(activity: activity)
        }
    }

    func syncLdkNodePayments(_ payments: [PaymentDetails]) async throws {
        try await ServiceQueue.background(.core) {
            var addedCount = 0
            var updatedCount = 0
            var latestCaughtError: Error?

            for payment in payments {
                do {
                    let state: BitkitCore.PaymentState
                    switch payment.status {
                    case .failed:
                        state = .failed
                    case .pending:
                        state = .pending
                    case .succeeded:
                        state = .succeeded
                    }

                    if case .onchain(let txid, let txStatus) = payment.kind {
                        // Check if this transaction was replaced by RBF and should be ignored
                        if ActivityService.replacedTransactions.contains(txid) {
                            Logger.debug("Ignoring replaced transaction \(txid) during sync", context: "CoreService.syncLdkNodePayments")
                            continue
                        }
                        
                        if payment.direction == .outbound {
                            Logger.test("SENT PAYMENT")
                        }
                        
                        var isConfirmed = false
                        var confirmedTimestamp: UInt64?
                        if case .confirmed(let blockHash, let height, let timestamp) = txStatus {
                            isConfirmed = true
                            confirmedTimestamp = timestamp
                        }

                        // Ensure confirmTimestamp is at least equal to timestamp when confirmed
                        let timestamp = payment.latestUpdateTimestamp

                        if isConfirmed && confirmedTimestamp != nil && confirmedTimestamp! < timestamp {
                            confirmedTimestamp = timestamp
                        }

                        // Get existing activity to preserve certain flags like isBoosted
                        let existingActivity = try getActivityById(activityId: payment.id)
                        let preservedIsBoosted = if case .onchain(let existing) = existingActivity {
                            existing.isBoosted
                        } else {
                            false
                        }
                        
                        // Check if this is a replacement transaction (RBF) that should be marked as boosted
                        let isReplacementTransaction = ActivityService.replacementTransactions.contains(txid)
                        let shouldMarkAsBoosted = preservedIsBoosted || isReplacementTransaction
                        
                        if isReplacementTransaction {
                            Logger.debug("Found replacement transaction \(txid), marking as boosted", context: "CoreService.syncLdkNodePayments")
                            // Remove from tracking set since we've processed it
                            ActivityService.replacementTransactions.remove(txid)
                            
                            // Also clean up any old replaced transactions that might be lingering
                            // This helps prevent the replacedTransactions set from growing indefinitely
                            if ActivityService.replacedTransactions.count > 10 {
                                Logger.debug("Cleaning up old replaced transactions", context: "CoreService.syncLdkNodePayments")
                                ActivityService.replacedTransactions.removeAll()
                            }
                        }
                        
                        guard let value = payment.amountSats, value > 0 else {
                            Logger.warn("Ignoring payment with missing value, probably additional boosted tx")
                            return
                        }

                        let onchain = OnchainActivity(
                            id: payment.id,
                            txType: payment.direction == .outbound ? .sent : .received,
                            txId: txid,
                            value: value,
                            fee: (payment.feePaidMsat ?? 0) / 1000,
                            feeRate: 1, //TODO: get from somewhere
                            address: "todo_find_address",
                            confirmed: isConfirmed,
                            timestamp: timestamp,
                            isBoosted: shouldMarkAsBoosted, // Mark as boosted if it's a replacement transaction
                            isTransfer: false, //TODO: handle when paying for order
                            doesExist: true,
                            confirmTimestamp: confirmedTimestamp,
                            channelId: nil, //TODO: get from linked order
                            transferTxId: nil, //TODO: get from linked order
                            createdAt: UInt64(payment.creationTime.timeIntervalSince1970),
                            updatedAt: timestamp
                        )

                        if existingActivity != nil {
                            try updateActivity(activityId: payment.id, activity: .onchain(onchain))
                            print(payment)
                            updatedCount += 1
                        } else {
                            try upsertActivity(activity: .onchain(onchain))
                            print(payment)
                            addedCount += 1
                        }
                    } else if case .bolt11(let hash, let preimage, let secret) = payment.kind {
                        // Skip pending inbound payments, just means they created an invoice
                        guard !(payment.status == .pending && payment.direction == .inbound) else { continue }

                        let ln = LightningActivity(
                            id: payment.id,
                            txType: payment.direction == .outbound ? .sent : .received,
                            status: state,
                            value: UInt64(payment.amountSats ?? 0),
                            fee: nil, // TODO:
                            invoice: "lnbc123",
                            message: "",
                            timestamp: UInt64(payment.latestUpdateTimestamp),
                            preimage: nil,
                            createdAt: UInt64(payment.latestUpdateTimestamp),
                            updatedAt: UInt64(payment.latestUpdateTimestamp)
                        )

                        if (try getActivityById(activityId: payment.id)) != nil {
                            try updateActivity(activityId: payment.id, activity: .lightning(ln))
                            updatedCount += 1
                        } else {
                            try upsertActivity(activity: .lightning(ln))
                            addedCount += 1
                        }
                    }
                } catch {
                    Logger.error("Error syncing LDK payment: \(error)", context: "CoreService")
                    latestCaughtError = error
                }

                //case spontaneous(hash: PaymentHash, preimage: PaymentPreimage?)
            }

            //If any of the inserts failed, we want to throw the error up
            if let error = latestCaughtError {
                throw error
            }

            Logger.info("Synced LDK payments - Added: \(addedCount) - Updated: \(updatedCount)", context: "CoreService")
        }
    }

    func getActivity(id: String) async throws -> Activity? {
        try await ServiceQueue.background(.core) {
            try getActivityById(activityId: id)
        }
    }

    func get(
        filter: ActivityFilter? = nil,
        txType: PaymentType? = nil,
        tags: [String]? = nil,
        search: String? = nil,
        minDate: UInt64? = nil,
        maxDate: UInt64? = nil,
        limit: UInt32? = nil,
        sortDirection: SortDirection? = nil
    ) async throws -> [Activity] {
        try await ServiceQueue.background(.core) {
            try getActivities(
                filter: filter,
                txType: txType,
                tags: tags,
                search: search,
                minDate: minDate,
                maxDate: maxDate,
                limit: limit,
                sortDirection: sortDirection
            )
        }
    }

    func update(id: String, activity: Activity) async throws {
        try await ServiceQueue.background(.core) {
            try updateActivity(activityId: id, activity: activity)
        }
    }

    func delete(id: String) async throws -> Bool {
        try await ServiceQueue.background(.core) {
            try deleteActivityById(activityId: id)
        }
    }

    // MARK: - Tag Methods

    func appendTag(toActivity id: String, _ tags: [String]) async throws {
        try await ServiceQueue.background(.core) {
            try addTags(activityId: id, tags: tags)
        }
    }

    func dropTags(fromActivity id: String, _ tags: [String]) async throws {
        try await ServiceQueue.background(.core) {
            try removeTags(activityId: id, tags: tags)
        }
    }

    func tags(forActivity id: String) async throws -> [String] {
        try await ServiceQueue.background(.core) {
            try getTags(activityId: id)
        }
    }

    func allPossibleTags() async throws -> [String] {
        try await ServiceQueue.background(.core) {
            try getAllUniqueTags()
        }
    }

    func boostOnchainTransaction(activityId: String, feeRate: UInt32) async throws -> String {
        return try await ServiceQueue.background(.core) {
            // Get the existing activity
            guard let existingActivity = try getActivityById(activityId: activityId) else {
                throw AppError(message: "Activity not found", debugMessage: "Activity with ID \(activityId) not found")
            }
            
            // Only onchain activities can be boosted
            guard case .onchain(var onchainActivity) = existingActivity else {
                throw AppError(message: "Only onchain activities can be boosted", debugMessage: "Activity \(activityId) is not an onchain activity")
            }
            
            let txid: String
            
            if onchainActivity.txType == .received {
                Logger.info("Executing CPFP boost for incoming transaction", context: "CoreService.boostOnchainTransaction")
                Logger.debug("Parent transaction ID: \(onchainActivity.txId)", context: "CoreService.boostOnchainTransaction")
                
                // Use CPFP for incoming transactions
                txid = try await LightningService.shared.accelerateByCpfp(
                    txid: onchainActivity.txId,
                    satsPerVbyte: feeRate
                )
                
                Logger.info("CPFP transaction created successfully: \(txid)", context: "CoreService.boostOnchainTransaction")
                
                // For CPFP, mark the original activity as boosted (parent transaction still exists)
                onchainActivity.isBoosted = true
                try updateActivity(activityId: activityId, activity: .onchain(onchainActivity))
                Logger.info("Successfully marked activity \(activityId) as boosted via CPFP", context: "CoreService.boostOnchainTransaction")
            } else {
                Logger.info("Executing RBF boost for outgoing transaction", context: "CoreService.boostOnchainTransaction")
                Logger.debug("Original transaction ID: \(onchainActivity.txId)", context: "CoreService.boostOnchainTransaction")
                
                // Use RBF for outgoing transactions
                txid = try await LightningService.shared.bumpFeeByRbf(
                    txid: onchainActivity.txId,
                    satsPerVbyte: feeRate
                )
                
                Logger.info("RBF transaction created successfully: \(txid)", context: "CoreService.boostOnchainTransaction")
                
                // Track the replacement transaction so we can mark it as boosted when it syncs
                ActivityService.replacementTransactions.insert(txid)
                Logger.debug("Added replacement transaction \(txid) to tracking list", context: "CoreService.boostOnchainTransaction")
                
                // Track the original transaction ID so we can ignore it during sync
                ActivityService.replacedTransactions.insert(onchainActivity.txId)
                Logger.debug("Added original transaction \(onchainActivity.txId) to replaced transactions list", context: "CoreService.boostOnchainTransaction")
                
                // For RBF, delete the original activity since it's been replaced
                // The new transaction will be synced automatically from LDK
                Logger.debug("Attempting to delete original activity \(activityId) before RBF replacement", context: "CoreService.boostOnchainTransaction")
                
                // Use the proper delete function that returns a Bool
                let deleteResult = try deleteActivityById(activityId: activityId)
                Logger.info("Delete result for original activity \(activityId): \(deleteResult)", context: "CoreService.boostOnchainTransaction")
                
                // Double-check that the activity was deleted
                let checkActivity = try getActivityById(activityId: activityId)
                if checkActivity == nil {
                    Logger.info("Confirmed: Original activity \(activityId) was successfully deleted", context: "CoreService.boostOnchainTransaction")
                } else {
                    Logger.error("Warning: Original activity \(activityId) still exists after deletion attempt", context: "CoreService.boostOnchainTransaction")
                }
            }
            
            return txid
        }
    }

    func generateRandomTestData(count: Int = 100) async throws {
        try await ServiceQueue.background(.core) {
            let timestamp = UInt64(Date().timeIntervalSince1970)
            let possibleTags = ["coffee", "food", "shopping", "transport", "entertainment", "work", "friends", "family"]
            let possibleMessages = [
                "Coffee at Starbucks",
                "Lunch with friends",
                "Uber ride",
                "Movie tickets",
                "Groceries",
                "Work payment",
                "Gift for mom",
                "Split dinner bill",
                "Monthly rent",
                "Gym membership",
            ]

            for i in 0 ..< count {
                let isLightning = Bool.random()
                let value = UInt64.random(in: 1000 ... 1_000_000) // Random sats between 1k and 1M

                // Ensure that the activities are spread out over the last 30 days
                let offset: UInt64
                switch i % 4 {
                case 0: // Today
                    offset = 0
                case 1: // Yesterday
                    offset = 86400 // 24 hours * 60 minutes * 60 seconds
                case 2: // Last week
                    offset = 604800 // 7 days * 24 hours * 60 minutes * 60 seconds
                case 3: // Last month
                    offset = 2_629_800 // Approx. 30 days * 24 hours * 60 minutes * 60 seconds
                default:
                    offset = 0
                }

                let timestamp = timestamp - offset
                let txType: PaymentType = Bool.random() ? .sent : .received
                let status: BitkitCore.PaymentState = {
                    let random = Int.random(in: 0 ... 10)
                    if random < 8 { return .succeeded } // 80% chance
                    if random < 9 { return .pending } // 10% chance
                    return .failed // 10% chance
                }()

                let activity: Activity
                let id: String

                if isLightning {
                    id = "test-lightning-\(i)"
                    activity = .lightning(
                        LightningActivity(
                            id: id,
                            txType: txType,
                            status: status,
                            value: value,
                            fee: UInt64.random(in: 1 ... 1000),
                            invoice: "lnbc\(value)",
                            message: possibleMessages.randomElement() ?? "",
                            timestamp: timestamp,
                            preimage: Bool.random() ? "preimage\(i)" : nil,
                            createdAt: timestamp,
                            updatedAt: timestamp
                        ))
                } else {
                    id = "test-onchain-\(i)"
                    activity = .onchain(
                        OnchainActivity(
                            id: id,
                            txType: txType,
                            txId: String(repeating: "a", count: 64), // Mock txid
                            value: value,
                            fee: UInt64.random(in: 100 ... 10000),
                            feeRate: UInt64.random(in: 1 ... 100),
                            address: "bc1...\(i)",
                            confirmed: Bool.random(),
                            timestamp: timestamp,
                            isBoosted: Bool.random(),
                            isTransfer: Bool.random(),
                            doesExist: true,
                            confirmTimestamp: Bool.random() ? timestamp + 3600 : nil, // 1 hour later if confirmed
                            channelId: Bool.random() ? "channel\(i)" : nil,
                            transferTxId: nil,
                            createdAt: timestamp,
                            updatedAt: timestamp
                        ))
                }

                // Insert activity
                try insertActivity(activity: activity)

                // Add random tags (0-3 tags)
                let numTags = Int.random(in: 0 ... 3)
                if numTags > 0 {
                    let tags = Array(Set((0 ..< numTags).map { _ in possibleTags.randomElement()! }))
                    try await self.appendTag(toActivity: id, tags)
                }
            }
        }
    }
}

// MARK: - Blocktank Service

class BlocktankService {
    private let coreService: CoreService

    init(coreService: CoreService) {
        self.coreService = coreService
    }

    func info(refresh: Bool = true) async throws -> IBtInfo? {
        try await ServiceQueue.background(.core) {
            try await getInfo(refresh: refresh)
        }
    }

    func fees(refresh: Bool = true) async throws -> FeeRates? {
        try await info(refresh: refresh)?.onchain.feeRates
    }

    func createCjit(
        channelSizeSat: UInt64,
        invoiceSat: UInt64,
        invoiceDescription: String,
        nodeId: String,
        channelExpiryWeeks: UInt32,
        options: CreateCjitOptions
    ) async throws -> IcJitEntry {
        Logger.info("Creating CJIT invoice with channel size: \(channelSizeSat) and invoice amount: \(invoiceSat)", context: "BlocktankService")

        return try await ServiceQueue.background(.core) {
            try await createCjitEntry(
                channelSizeSat: channelSizeSat,
                invoiceSat: invoiceSat,
                invoiceDescription: invoiceDescription,
                nodeId: nodeId,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
        }
    }

    func cjitOrders(entryIds: [String]? = nil, filter: CJitStateEnum? = nil, refresh: Bool = true) async throws -> [IcJitEntry] {
        try await ServiceQueue.background(.core) {
            try await getCjitEntries(entryIds: entryIds, filter: filter, refresh: refresh)
        }
    }

    func newOrder(
        lspBalanceSat: UInt64,
        channelExpiryWeeks: UInt32,
        options: CreateOrderOptions
    ) async throws -> IBtOrder {
        try await ServiceQueue.background(.core) {
            try await createOrder(
                lspBalanceSat: lspBalanceSat,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
        }
    }

    func estimateFee(
        lspBalanceSat: UInt64,
        channelExpiryWeeks: UInt32,
        options: CreateOrderOptions? = nil
    ) async throws -> IBtEstimateFeeResponse2 {
        try await ServiceQueue.background(.core) {
            try await estimateOrderFeeFull(
                lspBalanceSat: lspBalanceSat,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
        }
    }

    func orders(orderIds: [String]? = nil, filter: BtOrderState2? = nil, refresh: Bool = true) async throws -> [IBtOrder] {
        try await ServiceQueue.background(.core) {
            try await getOrders(orderIds: orderIds, filter: filter, refresh: refresh)
        }
    }

    func open(orderId: String) async throws -> IBtOrder {
        guard let nodeId = LightningService.shared.nodeId else {
            throw AppError(serviceError: .nodeNotStarted)
        }

        let latestOrder = try await ServiceQueue.background(.core) {
            try await getOrders(orderIds: [orderId], filter: nil, refresh: true).first
        }

        guard latestOrder?.state2 == .paid else {
            throw AppError(message: "Order not paid", debugMessage: "Order state: \(String(describing: latestOrder?.state2))")
        }

        return try await ServiceQueue.background(.core) {
            try await openChannel(orderId: orderId, connectionString: nodeId)
        }
    }

    // MARK: Notifications

    func registerDeviceForNotifications(
        deviceToken: String, publicKey: String, features: [String], nodeId: String, isoTimestamp: String, signature: String
    ) async throws -> String {
        try await ServiceQueue.background(.core) {
            try await registerDevice(
                deviceToken: deviceToken,
                publicKey: publicKey,
                features: features,
                nodeId: nodeId,
                isoTimestamp: isoTimestamp,
                signature: signature,
                isProduction: !Env.isDebug,
                customUrl: Env.blocktankPushNotificationServer
            )
        }
    }

    func pushNotificationTest(deviceToken: String, secretMessage: String, notificationType: String?) async throws -> String {
        try await ServiceQueue.background(.core) {
            try await testNotification(
                deviceToken: deviceToken,
                secretMessage: secretMessage,
                notificationType: notificationType,
                customUrl: Env.blocktankPushNotificationServer
            )
        }
    }

    // MARK: Regtest only methods

    private func executeWithRetry<T>(maxRetries: Int = 6, operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?

        for attempt in 0 ..< maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                Logger.warn("Regtest operation failed on attempt \(attempt + 1)/\(maxRetries): \(error)", context: "BlocktankService")

                if attempt < maxRetries - 1 {
                    let sleepDuration = UInt64(1 << attempt) // Exponential backoff: 1, 2, 4, 8, 16 seconds
                    Logger.info("Retrying in \(sleepDuration) seconds...", context: "BlocktankService")
                    try await Task.sleep(nanoseconds: sleepDuration * 2_000_000_000)
                }
            }
        }

        throw lastError ?? AppError(message: "Unknown error during retry", debugMessage: nil)
    }

    func regtestMineBlocks(_ count: UInt32 = 1) async throws {
        guard Env.network == .regtest else {
            throw AppError(serviceError: .regtestOnlyMethod)
        }

        try await executeWithRetry {
            try await ServiceQueue.background(.core) {
                try await regtestMine(count: count)
            }
        }
    }

    func regtestDepositFunds(address: String, amountSat: UInt64) async throws -> String {
        guard Env.network == .regtest else {
            throw AppError(serviceError: .regtestOnlyMethod)
        }

        return try await executeWithRetry {
            try await ServiceQueue.background(.core) {
                try await regtestDeposit(address: address, amountSat: amountSat)
            }
        }
    }

    func regtestPayInvoice(_ invoice: String, amountSat: UInt64?) async throws -> String {
        guard Env.network == .regtest else {
            throw AppError(serviceError: .regtestOnlyMethod)
        }

        return try await executeWithRetry {
            try await ServiceQueue.background(.core) {
                try await regtestPay(invoice: invoice, amountSat: amountSat)
            }
        }
    }

    func regtestRemoteCloseChannel(channel: ChannelDetails, forceCloseAfterSeconds: UInt64?) async throws -> String {
        guard Env.network == .regtest else {
            throw AppError(serviceError: .regtestOnlyMethod)
        }

        guard let fundingTxo = channel.fundingTxo else {
            throw AppError(message: "Missing channel.fundingTxo", debugMessage: nil)
        }

        return try await executeWithRetry {
            try await ServiceQueue.background(.core) {
                try await regtestCloseChannel(fundingTxId: fundingTxo.txid, vout: fundingTxo.vout, forceCloseAfterS: forceCloseAfterSeconds)
            }
        }
    }
}

// MARK: - Utility Service

class UtilityService {
    private let coreService: CoreService

    init(coreService: CoreService) {
        self.coreService = coreService
    }

    func getAccountAddresses(
        walletIndex: Int = 0,
        isChange: Bool? = nil,
        startIndex: UInt32? = nil,
        count: UInt32? = nil
    ) async throws -> AccountAddresses {
        return try await ServiceQueue.background(.core) {
            guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
                throw AppError(message: "Mnemonic not found", debugMessage: "Unable to load mnemonic for wallet index \(walletIndex)")
            }

            let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))

            // Create the correct derivation path based on network
            let coinType = Env.network == .bitcoin ? "0" : "1"
            let derivationPath = "m/84'/\(coinType)'/0'/0"

            let response = try deriveBitcoinAddresses(
                mnemonicPhrase: mnemonic,
                derivationPathStr: derivationPath,
                network: Env.bitkitCoreNetwork,
                bip39Passphrase: passphrase,
                isChange: isChange,
                startIndex: startIndex,
                count: count
            )

            // Convert GetAddressesResponse to AccountAddresses
            let usedAddresses = response.addresses.compactMap { addr -> BitkitCore.AddressInfo? in
                // You would determine if an address is used based on your logic
                // For now, we'll create a basic conversion
                return BitkitCore.AddressInfo(
                    address: addr.address,
                    path: addr.path,
                    transfers: 0 // This would need to be determined from blockchain data
                )
            }

            let unusedAddresses = response.addresses.compactMap { addr -> BitkitCore.AddressInfo? in
                return BitkitCore.AddressInfo(
                    address: addr.address,
                    path: addr.path,
                    transfers: 0
                )
            }

            let changeAddresses: [BitkitCore.AddressInfo] = []

            return AccountAddresses(
                used: usedAddresses,
                unused: unusedAddresses,
                change: changeAddresses
            )
        }
    }

    /// Get balance for a specific address in satoshis using AddressChecker utility
    /// - Parameter address: The Bitcoin address to check
    /// - Returns: The current balance in satoshis
    func getAddressBalance(address: String) async throws -> UInt64 {
        let addressInfo = try await AddressChecker.getAddressInfo(address: address)

        // Calculate current balance: received - spent
        let received = UInt64(addressInfo.chain_stats.funded_txo_sum)
        let spent = UInt64(addressInfo.chain_stats.spent_txo_sum)

        // Handle potential underflow
        return received >= spent ? received - spent : 0
    }

    /// Get balances for multiple addresses using AddressChecker utility
    /// - Parameter addresses: Array of Bitcoin addresses to check
    /// - Returns: Dictionary mapping addresses to their balances in satoshis
    func getMultipleAddressBalances(addresses: [String]) async throws -> [String: UInt64] {
        var balances: [String: UInt64] = [:]

        // Fetch balances concurrently for better performance
        await withTaskGroup(of: (String, UInt64?).self) { group in
            for address in addresses {
                group.addTask {
                    do {
                        let balance = try await self.getAddressBalance(address: address)
                        return (address, balance)
                    } catch {
                        Logger.error("Failed to get balance for address \(address): \(error)", context: "UtilityService")
                        return (address, nil)
                    }
                }
            }

            for await (address, balance) in group {
                if let balance = balance {
                    balances[address] = balance
                }
            }
        }

        return balances
    }
}

// MARK: - Core Service requires shared init for both activity and blocktank services

class CoreService {
    static let shared = CoreService()
    private let walletIndex: Int

    lazy var activity: ActivityService = .init(coreService: self)
    lazy var blocktank: BlocktankService = .init(coreService: self)
    lazy var utility: UtilityService = .init(coreService: self)

    private init(walletIndex: Int = 0) {
        self.walletIndex = walletIndex

        _ = try! initDb(basePath: Env.bitkitCoreStorage(walletIndex: walletIndex).path)

        // First thing ever added to the core queue so guarenteed to run first before any of above functions on the same queue
        ServiceQueue.background(.core) {
            try initDb(basePath: Env.bitkitCoreStorage(walletIndex: walletIndex).path)
        } completion: { result in
            switch result {
            case .success(let value):
                Logger.info("bitkit-core database init: \(value)", context: "CoreService")
            case .failure(let error):
                Logger.error("bitkit-core database init failed: \(error)", context: "CoreService")
            }
        }

        ServiceQueue.background(.core) {
            try await updateBlocktankUrl(newUrl: Env.blocktankClientServer)
        } completion: { result in
            switch result {
            case .success():
                Logger.info("Blocktank URL updated to \(Env.blocktankBaseUrl)", context: "CoreService")
            case .failure(let error):
                Logger.error("Failed to update Blocktank URL: \(error)", context: "CoreService")
            }
        }
    }

    func checkGeoStatus() async throws -> Bool? {
        try await ServiceQueue.background(.core) {
            Logger.info("Checking geo status...", context: "GeoCheck")
            guard let url = URL(string: Env.geoCheckUrl) else {
                Logger.error("Invalid geocheck URL: \(Env.geoCheckUrl)", context: "GeoCheck")
                return nil
            }

            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                Logger.debug("Received geo status response: \(httpResponse.statusCode)", context: "GeoCheck")
                switch httpResponse.statusCode {
                case 200:
                    Logger.info("Region allowed", context: "GeoCheck")
                    return false
                case 403:
                    Logger.warn("Region blocked", context: "GeoCheck")
                    return true
                default:
                    Logger.warn("Unexpected status code: \(httpResponse.statusCode)", context: "GeoCheck")
                    return nil
                }
            }
            return nil
        }
    }
}
