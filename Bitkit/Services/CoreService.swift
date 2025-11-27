import BitkitCore
import Combine
import Foundation
import LDKNode

// MARK: - Activity Service

class ActivityService {
    private let coreService: CoreService

    private let activitiesChangedSubject = PassthroughSubject<Void, Never>()

    var activitiesChangedPublisher: AnyPublisher<Void, Never> {
        activitiesChangedSubject.eraseToAnyPublisher()
    }

    private let metadataChangedSubject = PassthroughSubject<Void, Never>()

    var metadataChangedPublisher: AnyPublisher<Void, Never> {
        metadataChangedSubject.eraseToAnyPublisher()
    }

    // MARK: - Constants

    /// Maximum address index to search when current address exists
    private static let maxAddressSearchIndex: UInt32 = 100_000

    // MARK: - Transaction Status Checks

    func wasTransactionReplaced(txid: String) async -> Bool {
        // Check if the activity exists and is marked as replaced
        if let onchain = try? await getOnchainActivityByTxId(txid: txid),
           !onchain.doesExist
        {
            return true
        }

        return false
    }

    func shouldShowReceivedSheet(txid: String, value: UInt64) async -> Bool {
        if value == 0 {
            return false
        }

        // Don't show sheet for channel closure transactions
        if await findClosedChannelForTransaction(txid: txid, transactionDetails: nil) != nil {
            return false
        }

        do {
            // Check if this transaction's activity has boostTxIds (meaning it replaced other transactions)
            // If any of the replaced transactions have the same value, don't show the sheet
            guard let onchain = try? await getOnchainActivityByTxId(txid: txid),
                  !onchain.boostTxIds.isEmpty
            else {
                return true
            }

            // This transaction replaced others - check if any have the same value
            for replacedTxid in onchain.boostTxIds {
                if let replaced = try? await getOnchainActivityByTxId(txid: replacedTxid),
                   replaced.value == value
                {
                    Logger.info(
                        "Skipping received sheet for replacement transaction \(txid) with same value as replaced transaction \(replacedTxid)",
                        context: "CoreService.shouldShowReceivedSheet"
                    )
                    return false
                }
            }
        } catch {
            Logger.error("Failed to check existing activities for replacement: \(error)", context: "CoreService.shouldShowReceivedSheet")
        }

        return true
    }

    func isReceivedTransaction(txid: String) async -> Bool {
        guard let payments = LightningService.shared.payments,
              let payment = payments.first(where: { payment in
                  if case let .onchain(paymentTxid, _) = payment.kind {
                      return paymentTxid == txid
                  }
                  return false
              })
        else { return false }

        return payment.direction == .inbound
    }

    /// Get doesExist status for boostTxIds to determine RBF vs CPFP. RBF transactions have doesExist = false (replaced), CPFP transactions have
    /// doesExist = true (child transactions).
    func getBoostTxDoesExist(boostTxIds: [String]) async -> [String: Bool] {
        var doesExistMap: [String: Bool] = [:]
        for boostTxId in boostTxIds {
            if let boostActivity = try? await getOnchainActivityByTxId(txid: boostTxId) {
                doesExistMap[boostTxId] = boostActivity.doesExist
            }
        }
        return doesExistMap
    }

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
                filter: .all, txType: nil, tags: nil, search: nil, minDate: nil, maxDate: nil, limit: nil, sortDirection: nil
            )
            for activity in activities {
                let id: String = switch activity {
                case let .lightning(ln): ln.id
                case let .onchain(on): on.id
                }

                _ = try deleteActivityById(activityId: id)
            }

            self.activitiesChangedSubject.send()
        }
    }

    func insert(_ activity: Activity) async throws {
        try await ServiceQueue.background(.core) {
            try insertActivity(activity: activity)
            self.activitiesChangedSubject.send()
        }
    }

    func upsertList(_ activities: [Activity]) async throws {
        try await ServiceQueue.background(.core) {
            try upsertActivities(activities: activities)
        }
    }

    func closedChannels(sortDirection: SortDirection = .asc) async throws -> [ClosedChannelDetails] {
        try await ServiceQueue.background(.core) {
            try getAllClosedChannels(sortDirection: sortDirection)
        }
    }

    func upsertClosedChannelList(_ closedChannels: [ClosedChannelDetails]) async throws {
        try await ServiceQueue.background(.core) {
            try upsertClosedChannels(channels: closedChannels)
        }
    }

    func upsertClosedChannel(_ closedChannel: ClosedChannelDetails) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.upsertClosedChannel(channel: closedChannel)
        }
    }

    // MARK: - Payment Processing

    private func processOnchainPayment(
        _ payment: PaymentDetails,
        transactionDetails: TransactionDetails? = nil
    ) async throws {
        guard case let .onchain(txid, _) = payment.kind else { return }

        let paymentTimestamp = payment.latestUpdateTimestamp
        let existingActivity = try getActivityById(activityId: payment.id)

        // Skip if existing activity has newer timestamp to avoid overwriting local data
        if let existingActivity, case let .onchain(existing) = existingActivity {
            let existingUpdatedAt = existing.updatedAt ?? 0
            if existingUpdatedAt > paymentTimestamp {
                return
            }
        }

        // Determine confirmation status from payment's txStatus
        let value = payment.amountSats ?? 0

        // Determine confirmation status from payment's txStatus
        // Ensure confirmTimestamp is at least equal to paymentTimestamp when confirmed
        // This handles cases where payment.latestUpdateTimestamp is more recent than blockTimestamp
        let (isConfirmed, confirmedTimestamp): (Bool, UInt64?) =
            if case let .onchain(_, txStatus) = payment.kind,
            case let .confirmed(_, _, blockTimestamp) = txStatus {
                (true, max(blockTimestamp, paymentTimestamp))
            } else {
                (false, nil)
            }

        // Extract existing activity data
        let existingOnchain: OnchainActivity? = {
            if let existingActivity, case let .onchain(existing) = existingActivity {
                return existing
            }
            return nil
        }()

        let isBoosted = existingOnchain?.isBoosted ?? false
        let boostTxIds = existingOnchain?.boostTxIds ?? []
        var isTransfer = existingOnchain?.isTransfer ?? false
        var channelId = existingOnchain?.channelId
        let transferTxId = existingOnchain?.transferTxId
        let feeRate = existingOnchain?.feeRate ?? 1
        let preservedAddress = existingOnchain?.address ?? "Loading..."
        let doesExist = existingOnchain?.doesExist ?? true

        // Check if this transaction is a channel transfer
        if channelId == nil || !isTransfer {
            let foundChannelId = await findChannelForTransaction(
                txid: txid,
                direction: payment.direction,
                transactionDetails: transactionDetails
            )
            if let foundChannelId {
                channelId = foundChannelId
                isTransfer = true
            }
        }

        // Find receiving address for inbound transactions
        var address = preservedAddress
        if payment.direction == .inbound {
            do {
                if let foundAddress = try await findReceivingAddress(
                    for: txid,
                    value: value,
                    transactionDetails: transactionDetails
                ) {
                    address = foundAddress
                }
            } catch {
                Logger.error("Failed to find address for txid \(txid): \(error)", context: "CoreService.processOnchainPayment")
            }
        }

        // Build and save the activity
        let finalDoesExist = isConfirmed ? true : doesExist

        let onchain = OnchainActivity(
            id: payment.id,
            txType: payment.direction == .outbound ? .sent : .received,
            txId: txid,
            value: value,
            fee: (payment.feePaidMsat ?? 0) / 1000,
            feeRate: feeRate,
            address: address,
            confirmed: isConfirmed,
            timestamp: paymentTimestamp,
            isBoosted: isBoosted,
            boostTxIds: boostTxIds,
            isTransfer: isTransfer,
            doesExist: finalDoesExist,
            confirmTimestamp: confirmedTimestamp,
            channelId: channelId,
            transferTxId: transferTxId,
            createdAt: UInt64(payment.creationTime.timeIntervalSince1970),
            updatedAt: paymentTimestamp
        )

        if existingActivity != nil {
            try await update(id: payment.id, activity: .onchain(onchain))
        } else {
            try await upsert(.onchain(onchain))
        }
    }

    // MARK: - Onchain Event Handlers

    private func processOnchainTransaction(txid: String, details: TransactionDetails, context: String) async throws {
        guard let payments = LightningService.shared.payments else {
            Logger.warn("No payments available for transaction \(txid)", context: context)
            return
        }

        guard let payment = payments.first(where: { payment in
            if case let .onchain(paymentTxid, _) = payment.kind {
                return paymentTxid == txid
            }
            return false
        }) else {
            Logger.warn("Payment not found for transaction \(txid) - LDK should have updated payment store before emitting event", context: context)
            return
        }

        try await processOnchainPayment(payment, transactionDetails: details)
    }

    func handleOnchainTransactionReceived(txid: String, details: TransactionDetails) async throws {
        try await ServiceQueue.background(.core) {
            try await self.processOnchainTransaction(txid: txid, details: details, context: "CoreService.handleOnchainTransactionReceived")
        }
    }

    func handleOnchainTransactionConfirmed(txid: String, details: TransactionDetails) async throws {
        try await ServiceQueue.background(.core) {
            try await self.processOnchainTransaction(txid: txid, details: details, context: "CoreService.handleOnchainTransactionConfirmed")
        }
    }

    func handleOnchainTransactionReplaced(txid: String, conflicts: [String]) async throws {
        try await ServiceQueue.background(.core) {
            // Find the activity for the replaced transaction
            let replacedActivity = try await self.getOnchainActivityByTxId(txid: txid)

            let replacedTags: [String]
            if var existing = replacedActivity {
                replacedTags = await (try? self.tags(forActivity: existing.id)) ?? []

                Logger.info(
                    "Transaction \(txid) replaced by \(conflicts.count) conflict(s): \(conflicts.joined(separator: ", "))",
                    context: "CoreService.handleOnchainTransactionReplaced"
                )

                // Mark the replaced transaction as not existing
                existing.doesExist = false
                existing.updatedAt = UInt64(Date().timeIntervalSince1970)
                try await self.update(id: existing.id, activity: .onchain(existing))
                Logger.info("Marked transaction \(txid) as replaced", context: "CoreService.handleOnchainTransactionReplaced")
            } else {
                replacedTags = []
                Logger.info(
                    "Activity not found for replaced transaction \(txid) - was deleted by initiated RBF, tags in pre-activity metadata",
                    context: "CoreService.handleOnchainTransactionReplaced"
                )
            }

            // For each replacement transaction, update its boostTxIds to include the replaced txid
            for conflictTxid in conflicts {
                // Try to get the replacement activity, or process it if it doesn't exist
                var replacementActivity = try? await self.getOnchainActivityByTxId(txid: conflictTxid)

                if replacementActivity == nil,
                   let payments = LightningService.shared.payments,
                   let replacementPayment = payments.first(where: { payment in
                       if case let .onchain(paymentTxid, _) = payment.kind {
                           return paymentTxid == conflictTxid
                       }
                       return false
                   })
                {
                    Logger.info(
                        "Processing replacement transaction \(conflictTxid) that was already in payments list",
                        context: "CoreService.handleOnchainTransactionReplaced"
                    )
                    do {
                        try await self.processOnchainPayment(replacementPayment, transactionDetails: nil)
                        replacementActivity = try? await self.getOnchainActivityByTxId(txid: conflictTxid)
                    } catch {
                        Logger.error(
                            "Failed to process replacement transaction \(conflictTxid): \(error)",
                            context: "CoreService.handleOnchainTransactionReplaced"
                        )
                        continue
                    }
                }

                // Update the replacement transaction's boostTxIds to include the replaced txid
                if var activity = replacementActivity,
                   !activity.boostTxIds.contains(txid)
                {
                    activity.boostTxIds.append(txid)
                    activity.isBoosted = true
                    activity.updatedAt = UInt64(Date().timeIntervalSince1970)
                    try await self.update(id: activity.id, activity: .onchain(activity))

                    // Apply tags from the replaced transaction
                    if !replacedTags.isEmpty {
                        do {
                            try await self.appendTags(toActivity: activity.id, replacedTags)
                        } catch {
                            Logger.error(
                                "Failed to apply tags from replaced transaction \(txid) to replacement transaction \(conflictTxid): \(error)",
                                context: "CoreService.handleOnchainTransactionReplaced"
                            )
                        }
                    }

                    Logger.info(
                        "Updated replacement transaction \(conflictTxid) with boostTxId \(txid)",
                        context: "CoreService.handleOnchainTransactionReplaced"
                    )
                }
            }

            self.activitiesChangedSubject.send()
        }
    }

    func handleOnchainTransactionReorged(txid: String) async throws {
        try await ServiceQueue.background(.core) {
            guard var onchain = try await self.getOnchainActivityByTxId(txid: txid) else {
                Logger.warn("Activity not found for reorged transaction \(txid)", context: "CoreService.handleOnchainTransactionReorged")
                return
            }

            onchain.confirmed = false
            onchain.confirmTimestamp = nil
            onchain.updatedAt = UInt64(Date().timeIntervalSince1970)

            try await self.update(id: onchain.id, activity: .onchain(onchain))
        }
    }

    func handleOnchainTransactionEvicted(txid: String) async throws {
        try await ServiceQueue.background(.core) {
            guard var onchain = try await self.getOnchainActivityByTxId(txid: txid) else {
                Logger.warn("Activity not found for evicted transaction \(txid)", context: "CoreService.handleOnchainTransactionEvicted")
                return
            }

            onchain.doesExist = false
            onchain.updatedAt = UInt64(Date().timeIntervalSince1970)

            try await self.update(id: onchain.id, activity: .onchain(onchain))
        }
    }

    // MARK: - Lightning Event Handlers

    /// Handle a single payment event by processing the specific payment
    func handlePaymentEvent(paymentHash: String) async throws {
        try await ServiceQueue.background(.core) {
            guard let payments = LightningService.shared.payments else {
                Logger.warn("No payments available for hash \(paymentHash)", context: "CoreService.handlePaymentEvent")
                return
            }

            if let payment = payments.first(where: { $0.id == paymentHash }) {
                try await self.processLightningPayment(payment)
            } else {
                Logger.info("Payment not found for hash \(paymentHash) - syncing all payments", context: "CoreService.handlePaymentEvent")
                try await self.syncLdkNodePayments(payments)
            }
        }
    }

    private func processLightningPayment(_ payment: PaymentDetails) async throws {
        guard case let .bolt11(hash, preimage, secret, description, bolt11) = payment.kind else { return }

        // Skip pending inbound payments - just means they created an invoice
        guard !(payment.status == .pending && payment.direction == .inbound) else { return }

        let paymentTimestamp = UInt64(payment.latestUpdateTimestamp)
        let existingActivity = try getActivityById(activityId: payment.id)

        // Skip if existing activity has newer timestamp to avoid overwriting local data
        if let existingActivity, case let .lightning(existing) = existingActivity {
            let existingUpdatedAt = existing.updatedAt ?? 0
            if existingUpdatedAt > paymentTimestamp {
                return
            }
        }

        let state: BitkitCore.PaymentState = switch payment.status {
        case .failed: .failed
        case .pending: .pending
        case .succeeded: .succeeded
        }

        let ln = LightningActivity(
            id: payment.id,
            txType: payment.direction == .outbound ? .sent : .received,
            status: state,
            value: UInt64(payment.amountSats ?? 0),
            fee: (payment.feePaidMsat ?? 0) / 1000,
            invoice: bolt11 ?? "No invoice",
            message: description ?? "",
            timestamp: paymentTimestamp,
            preimage: preimage,
            createdAt: paymentTimestamp,
            updatedAt: paymentTimestamp
        )

        if existingActivity != nil {
            try await update(id: payment.id, activity: .lightning(ln))
        } else {
            try await upsert(.lightning(ln))
        }
    }

    /// Sync all LDK node payments to activities
    /// Use for initial wallet load, manual refresh, or after operations that create new payments.
    /// Events handle individual payment updates, so this should not be called on every event.
    func syncLdkNodePayments(_ payments: [PaymentDetails]) async throws {
        try await ServiceQueue.background(.core) {
            var addedCount = 0
            var updatedCount = 0
            var latestCaughtError: Error?

            for payment in payments {
                do {
                    let state: BitkitCore.PaymentState = switch payment.status {
                    case .failed:
                        .failed
                    case .pending:
                        .pending
                    case .succeeded:
                        .succeeded
                    }

                    if case let .onchain(txid, _) = payment.kind {
                        do {
                            let hadExistingActivity = try getActivityById(activityId: payment.id) != nil
                            try await self.processOnchainPayment(payment, transactionDetails: nil)
                            if hadExistingActivity {
                                updatedCount += 1
                            } else {
                                addedCount += 1
                            }
                        } catch {
                            Logger.error("Error processing onchain payment \(txid): \(error)", context: "CoreService.syncLdkNodePayments")
                            latestCaughtError = error
                        }
                    } else if case .bolt11 = payment.kind {
                        do {
                            let hadExistingActivity = try getActivityById(activityId: payment.id) != nil
                            try await self.processLightningPayment(payment)
                            if hadExistingActivity {
                                updatedCount += 1
                            } else {
                                addedCount += 1
                            }
                        } catch {
                            Logger.error("Error processing lightning payment \(payment.id): \(error)", context: "CoreService.syncLdkNodePayments")
                            latestCaughtError = error
                        }
                    }
                } catch {
                    Logger.error("Error syncing LDK payment: \(error)", context: "CoreService")
                    latestCaughtError = error
                }
            }

            // If any of the inserts failed, we want to throw the error up
            if let error = latestCaughtError {
                throw error
            }

            Logger.info("Synced LDK payments - Added: \(addedCount) - Updated: \(updatedCount)", context: "CoreService")
            self.activitiesChangedSubject.send()
        }
    }

    /// Marks replacement transactions (with originalTxId in boostTxIds) as doesExist = false when original confirms
    /// Finds the channel ID associated with a transaction based on its direction
    private func findChannelForTransaction(txid: String, direction: PaymentDirection, transactionDetails: TransactionDetails? = nil) async -> String?
    {
        switch direction {
        case .inbound:
            // Check if this transaction is a channel close by checking if it spends a closed channel's funding UTXO
            return await findClosedChannelForTransaction(txid: txid, transactionDetails: transactionDetails)
        case .outbound:
            // Check if this transaction is a channel open by checking if it's the funding transaction for an open channel
            return await findOpenChannelForTransaction(txid: txid)
        }
    }

    /// Check if a transaction spends a closed channel's funding UTXO
    private func findClosedChannelForTransaction(txid: String, transactionDetails: TransactionDetails? = nil) async -> String? {
        do {
            let closedChannels = try await getAllClosedChannels(sortDirection: .desc)
            guard !closedChannels.isEmpty else { return nil }

            // Use provided transaction details if available, otherwise try node
            guard let details = transactionDetails ?? LightningService.shared.getTransactionDetails(txid: txid) else {
                Logger.warn("Transaction details not available for \(txid)", context: "CoreService.findClosedChannelForTransaction")
                return nil
            }

            // Check if any input spends a closed channel's funding UTXO
            for input in details.inputs {
                let inputTxid = input.txid
                let inputVout = Int(input.vout)

                if let matchingChannel = closedChannels.first(where: { channel in
                    channel.fundingTxoTxid == inputTxid && channel.fundingTxoIndex == UInt32(inputVout)
                }) {
                    return matchingChannel.channelId
                }
            }
        } catch {
            Logger.warn(
                "Failed to check if transaction \(txid) spends closed channel funding UTXO: \(error)",
                context: "CoreService.findClosedChannelForTransaction"
            )
        }

        return nil
    }

    /// Check if a transaction is the funding transaction for an open channel
    private func findOpenChannelForTransaction(txid: String) async -> String? {
        guard let channels = LightningService.shared.channels, !channels.isEmpty else {
            return nil
        }

        // First, check if the transaction matches any channel's funding transaction directly
        if let channel = channels.first(where: { $0.fundingTxo?.txid.description == txid }) {
            return channel.channelId.description
        }

        // If no direct match, check Blocktank orders for payment transactions
        do {
            let orders = try await coreService.blocktank.orders(orderIds: nil, filter: nil, refresh: false)

            // Find order with matching payment transaction
            guard let order = orders.first(where: { order in
                order.payment?.onchain?.transactions.contains { $0.txId == txid } ?? false
            }) else {
                return nil
            }

            // Find channel that matches this order's channel funding transaction
            guard let orderChannel = order.channel else {
                return nil
            }

            if let channel = channels.first(where: { channel in
                channel.fundingTxo?.txid.description == orderChannel.fundingTx.id
            }) {
                return channel.channelId.description
            }
        } catch {
            Logger.warn(
                "Failed to fetch Blocktank orders: \(error)",
                context: "CoreService.findOpenChannelForTransaction"
            )
        }

        return nil
    }

    /// Check pre-activity metadata for addresses in the transaction
    private func findAddressInPreActivityMetadata(details: TransactionDetails, value: UInt64) async -> String? {
        for output in details.outputs {
            guard let address = output.scriptpubkeyAddress else { continue }
            if let metadata = try? await getPreActivityMetadata(searchKey: address, searchByAddress: true),
               metadata.isReceive
            {
                return address
            }
        }

        return nil
    }

    /// Find the receiving address for an onchain transaction
    private func findReceivingAddress(for txid: String, value: UInt64, transactionDetails: TransactionDetails? = nil) async throws -> String? {
        // Use provided transaction details if available, otherwise try node
        guard let details = transactionDetails ?? LightningService.shared.getTransactionDetails(txid: txid) else {
            Logger.warn("Transaction details not available for \(txid)", context: "CoreService.findReceivingAddress")
            return nil
        }

        let batchSize: UInt32 = 20
        let currentWalletAddress = UserDefaults.standard.string(forKey: "onchainAddress") ?? ""

        // Check if an address matches any transaction output
        func matchesTransaction(_ address: String) -> Bool {
            details.outputs.contains { output in
                output.scriptpubkeyAddress == address
            }
        }

        // Find matching address from a list, preferring exact value match
        func findMatch(in addresses: [String]) -> String? {
            // Try exact value match first
            for address in addresses {
                for output in details.outputs {
                    if output.scriptpubkeyAddress == address,
                       output.value == value
                    {
                        return address
                    }
                }
            }
            // Fallback to any address match
            for address in addresses {
                if matchesTransaction(address) {
                    return address
                }
            }
            return nil
        }

        // First, check pre-activity metadata for addresses in the transaction
        if let address = await findAddressInPreActivityMetadata(details: details, value: value) {
            return address
        }

        // Check current address if it exists
        if !currentWalletAddress.isEmpty && matchesTransaction(currentWalletAddress) {
            return currentWalletAddress
        }

        // Search addresses forward in batches
        func searchAddresses(isChange: Bool) async throws -> String? {
            var index: UInt32 = 0
            var currentAddressIndex: UInt32? = nil
            let hasCurrentAddress = !currentWalletAddress.isEmpty
            let maxIndex: UInt32 = hasCurrentAddress ? Self.maxAddressSearchIndex : batchSize

            while index < maxIndex {
                let accountAddresses = try await coreService.utility.getAccountAddresses(
                    walletIndex: 0,
                    isChange: isChange,
                    startIndex: index,
                    count: batchSize
                )

                let addresses = accountAddresses.unused.map(\.address) + accountAddresses.used.map(\.address)

                // Track when we find the current address
                if hasCurrentAddress, currentAddressIndex == nil, addresses.contains(currentWalletAddress) {
                    currentAddressIndex = index
                }

                // Check for matches
                if let match = findMatch(in: addresses) {
                    return match
                }

                // Stop if we've checked one batch after finding current address
                if let foundIndex = currentAddressIndex, index >= foundIndex + batchSize {
                    break
                }

                // Stop if we've reached the end
                if addresses.count < Int(batchSize) {
                    break
                }

                index += batchSize
            }
            return nil
        }

        // Try receiving addresses first, then change addresses
        if let address = try await searchAddresses(isChange: false) {
            return address
        }
        if let address = try await searchAddresses(isChange: true) {
            return address
        }

        // Fallback: return first output address
        return details.outputs.first?.scriptpubkeyAddress
    }

    func getActivity(id: String) async throws -> Activity? {
        try await ServiceQueue.background(.core) {
            try getActivityById(activityId: id)
        }
    }

    func getOnchainActivityByTxId(txid: String) async throws -> OnchainActivity? {
        try await ServiceQueue.background(.core) {
            try BitkitCore.getActivityByTxId(txId: txid)
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
            self.activitiesChangedSubject.send()
        }
    }

    func upsert(_ activity: Activity) async throws {
        try await ServiceQueue.background(.core) {
            try upsertActivity(activity: activity)
            self.activitiesChangedSubject.send()
        }
    }

    func delete(id: String) async throws -> Bool {
        try await ServiceQueue.background(.core) {
            let result = try deleteActivityById(activityId: id)
            self.activitiesChangedSubject.send()
            return result
        }
    }

    // MARK: - Tag Methods

    func appendTags(toActivity id: String, _ tags: [String]) async throws {
        try await ServiceQueue.background(.core) {
            try addTags(activityId: id, tags: tags)
            self.activitiesChangedSubject.send()
        }
    }

    func dropTags(fromActivity id: String, _ tags: [String]) async throws {
        try await ServiceQueue.background(.core) {
            try removeTags(activityId: id, tags: tags)
            self.activitiesChangedSubject.send()
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

    func getAllActivitiesTags() async throws -> [ActivityTags] {
        try await ServiceQueue.background(.core) {
            try BitkitCore.getAllActivitiesTags()
        }
    }

    func upsertTags(_ activityTags: [ActivityTags]) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.upsertTags(activityTags: activityTags)
        }
    }

    // MARK: - Pre-Activity Metadata Methods

    func addPreActivityMetadata(_ preActivityMetadata: BitkitCore.PreActivityMetadata) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.addPreActivityMetadata(preActivityMetadata: preActivityMetadata)
            self.metadataChangedSubject.send()
        }
    }

    func addPreActivityMetadataTags(paymentId: String, tags: [String]) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.addPreActivityMetadataTags(paymentId: paymentId, tags: tags)
            self.metadataChangedSubject.send()
        }
    }

    func removePreActivityMetadataTags(paymentId: String, tags: [String]) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.removePreActivityMetadataTags(paymentId: paymentId, tags: tags)
            self.metadataChangedSubject.send()
        }
    }

    func getPreActivityMetadata(searchKey: String, searchByAddress: Bool = false) async throws -> BitkitCore.PreActivityMetadata? {
        try await ServiceQueue.background(.core) {
            try BitkitCore.getPreActivityMetadata(searchKey: searchKey, searchByAddress: searchByAddress)
        }
    }

    func deletePreActivityMetadata(paymentId: String) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.deletePreActivityMetadata(paymentId: paymentId)
            self.metadataChangedSubject.send()
        }
    }

    func resetPreActivityMetadataTags(paymentId: String) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.resetPreActivityMetadataTags(paymentId: paymentId)
            self.metadataChangedSubject.send()
        }
    }

    // MARK: - Pre-Activity Metadata Methods (for backup service)

    func upsertPreActivityMetadata(_ preActivityMetadata: [BitkitCore.PreActivityMetadata]) async throws {
        try await ServiceQueue.background(.core) {
            try BitkitCore.upsertPreActivityMetadata(preActivityMetadata: preActivityMetadata)
        }
    }

    func getAllPreActivityMetadata() async throws -> [BitkitCore.PreActivityMetadata] {
        try await ServiceQueue.background(.core) {
            try BitkitCore.getAllPreActivityMetadata()
        }
    }

    func boostOnchainTransaction(activityId: String, feeRate: UInt32) async throws -> String {
        return try await ServiceQueue.background(.core) {
            // Get the existing activity
            guard let existingActivity = try getActivityById(activityId: activityId) else {
                throw AppError(message: "Activity not found", debugMessage: "Activity with ID \(activityId) not found")
            }

            // Only onchain activities can be boosted
            guard case var .onchain(onchainActivity) = existingActivity else {
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
                onchainActivity.boostTxIds.append(txid)
                try await self.update(id: activityId, activity: .onchain(onchainActivity))
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

                // Get tags from the old activity before deleting it
                let oldTags = await (try? self.tags(forActivity: activityId)) ?? []

                // Create pre-activity metadata for the replacement transaction with tags from the old activity
                if !oldTags.isEmpty {
                    let currentTime = UInt64(Date().timeIntervalSince1970)
                    let preActivityMetadata = BitkitCore.PreActivityMetadata(
                        paymentId: txid,
                        tags: oldTags,
                        paymentHash: nil,
                        txId: txid,
                        address: onchainActivity.address,
                        isReceive: false,
                        feeRate: UInt64(feeRate),
                        isTransfer: onchainActivity.isTransfer,
                        channelId: onchainActivity.channelId,
                        createdAt: currentTime
                    )
                    try? await self.addPreActivityMetadata(preActivityMetadata)
                    Logger.info(
                        "Created pre-activity metadata with \(oldTags.count) tag(s) for RBF replacement transaction \(txid)",
                        context: "CoreService.boostOnchainTransaction"
                    )
                }

                // For RBF we initiated, delete the old activity
                _ = try await self.delete(id: activityId)
                Logger.info(
                    "Successfully deleted activity \(activityId) (replaced by RBF transaction \(txid))",
                    context: "CoreService.boostOnchainTransaction"
                )
            }

            return txid
        }
    }

    func generateRandomTestData() async throws {
        let testDataSets = generateTestDataSets()

        try await ServiceQueue.background(.core) {
            var activityId = 0

            for (periodName, baseTimestamp, activities) in testDataSets {
                Logger.info("Generating \(periodName) test data with \(activities.count) activities", context: "CoreService")

                for template in activities {
                    let timestamp = baseTimestamp + UInt64.random(in: 0 ... 3600) // Add some randomness within the day
                    let id = "test-\(periodName.lowercased())-\(template.type.rawValue)-\(activityId)"

                    let activity: Activity = switch template.type {
                    case .lightning:
                        .lightning(
                            LightningActivity(
                                id: id,
                                txType: template.txType,
                                status: template.status,
                                value: template.value,
                                fee: UInt64.random(in: 1 ... 1000),
                                invoice: "lnbc\(template.value)",
                                message: template.message,
                                timestamp: timestamp,
                                preimage: template.status == .succeeded ? "preimage\(activityId)" : nil,
                                createdAt: timestamp,
                                updatedAt: timestamp
                            )
                        )
                    case .onchain:
                        .onchain(
                            OnchainActivity(
                                id: id,
                                txType: template.txType,
                                txId: String(repeating: "a", count: 64),
                                value: template.value,
                                fee: UInt64.random(in: 100 ... 200),
                                feeRate: UInt64.random(in: 1 ... 5),
                                address: "bc1...\(activityId)",
                                confirmed: template.confirmed ?? false,
                                timestamp: timestamp,
                                isBoosted: template.isBoosted ?? false,
                                boostTxIds: template.boostTxIds,
                                isTransfer: template.isTransfer ?? false,
                                doesExist: true,
                                confirmTimestamp: template.confirmed == true ? timestamp + 3600 : nil,
                                channelId: nil,
                                transferTxId: nil,
                                createdAt: timestamp,
                                updatedAt: timestamp
                            )
                        )
                    }

                    // Insert activity
                    try insertActivity(activity: activity)

                    // Add tags
                    if !template.tags.isEmpty {
                        try await self.appendTags(toActivity: id, template.tags)
                    }

                    activityId += 1
                }
            }

            Logger.info("Generated \(activityId) test activities across all time periods", context: "CoreService")
            self.activitiesChangedSubject.send()
        }
    }
}

// MARK: - Test Data Generation (Development Only)

private struct ActivityTemplate {
    enum ActivityType: String {
        case lightning
        case onchain
    }

    let type: ActivityType
    let txType: PaymentType
    let status: BitkitCore.PaymentState
    let value: UInt64
    let message: String
    let tags: [String]
    let confirmed: Bool?
    let isBoosted: Bool?
    let boostTxIds: [String]
    let isTransfer: Bool?

    init(
        type: ActivityType,
        txType: PaymentType,
        status: BitkitCore.PaymentState,
        value: UInt64,
        message: String,
        tags: [String] = [],
        confirmed: Bool? = nil,
        isBoosted: Bool? = nil,
        isTransfer: Bool? = nil,
        boostTxIds: [String] = []
    ) {
        self.type = type
        self.txType = txType
        self.status = status
        self.value = value
        self.message = message
        self.tags = tags
        self.confirmed = confirmed
        self.isBoosted = isBoosted
        self.isTransfer = isTransfer
        self.boostTxIds = boostTxIds
    }
}

private func generateTestDataSets() -> [(String, UInt64, [ActivityTemplate])] {
    let now = UInt64(Date().timeIntervalSince1970)
    let today = now
    let yesterday = now - 86400 // 24 hours ago
    let thisWeek = now - 3 * 86400 // 3 days ago
    let thisMonth = now - 15 * 86400 // 15 days ago
    let thisYear = now - 90 * 86400 // 90 days ago
    let earlier = now - 300 * 86400 // 300 days ago

    // swiftformat:disable all
    return [
        ("Today", today, [
            // Lightning activities for today
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 50000, message: "Coffee at Starbucks", tags: ["coffee"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 25000, message: "", tags: ["work"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .pending, value: 15000, message: "", tags: ["transport"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .failed, value: 10000, message: "", tags: []),
            
            // Onchain activities for today
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 800000, message: "Monthly rent", tags: ["work"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 20000, message: "", tags: [], confirmed: false, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 30000, message: "", tags: [], confirmed: false, isBoosted: true, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 100000, message: "", tags: [], confirmed: false, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 200000, message: "", tags: [], confirmed: false, isBoosted: true, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 75000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 20000, message: "", tags: [], confirmed: false, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 30000, message: "", tags: [], confirmed: false, isBoosted: true, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 100000, message: "", tags: [], confirmed: false, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 200000, message: "", tags: [], confirmed: false, isBoosted: true, isTransfer: true),
        ]),
        
        ("Yesterday", yesterday, [
            // Lightning activities for yesterday
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 35000, message: "Lunch with friends", tags: ["food", "friends"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 8000, message: "", tags: ["entertainment"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .failed, value: 12000, message: "", tags: ["food", "shopping"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .pending, value: 5000, message: "", tags: []),
            
            // Onchain activities for yesterday
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 200000, message: "Large purchase", tags: ["shopping"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 50000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 15000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 25000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
        ]),
        
        ("This Week", thisWeek, [
            // Lightning activities for this week
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 45000, message: "Gas station", tags: ["transport"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 18000, message: "Freelance work", tags: ["work"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 22000, message: "Online shopping", tags: ["shopping"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .failed, value: 12000, message: "", tags: []),
            
            // Onchain activities for this week
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 150000, message: "Car payment", tags: ["transport"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 80000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 25000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 30000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
        ]),
        
        ("This Month", thisMonth, [
            // Lightning activities for this month
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 60000, message: "Restaurant dinner", tags: ["food"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 35000, message: "", tags: ["work"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 28000, message: "", tags: ["entertainment"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .failed, value: 15000, message: "", tags: ["shopping"]),
            
            // Onchain activities for this month
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 300000, message: "Investment", tags: ["work"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 120000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 50000, message: "", tags: [], confirmed: true, isBoosted: true, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 40000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
        ]),
        
        ("This Year", thisYear, [
            // Lightning activities for this year
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 80000, message: "Vacation booking", tags: ["travel"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 120000, message: "", tags: ["work"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 45000, message: "", tags: ["shopping"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .failed, value: 25000, message: "", tags: ["family"]),
            
            // Onchain activities for this year
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 500000, message: "Home improvement", tags: ["work"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 200000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 75000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 60000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
        ]),
        
        ("Earlier", earlier, [
            // Lightning activities for earlier
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 100000, message: "Major purchase", tags: ["shopping"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .succeeded, value: 150000, message: "", tags: ["work"]),
            ActivityTemplate(type: .lightning, txType: .sent, status: .succeeded, value: 60000, message: "", tags: ["travel"]),
            ActivityTemplate(type: .lightning, txType: .received, status: .failed, value: 40000, message: "", tags: ["work"]),
            
            // Onchain activities for earlier
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 1000000, message: "Real estate", tags: ["work"], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 500000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: false),
            ActivityTemplate(type: .onchain, txType: .sent, status: .succeeded, value: 100000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
            ActivityTemplate(type: .onchain, txType: .received, status: .succeeded, value: 80000, message: "", tags: [], confirmed: true, isBoosted: false, isTransfer: true),
        ]),
    ]
    // swiftformat:enable all
}

// MARK: - Blocktank Service

class BlocktankService {
    private let coreService: CoreService

    private let stateChangedSubject = PassthroughSubject<Void, Never>()

    var stateChangedPublisher: AnyPublisher<Void, Never> {
        stateChangedSubject.eraseToAnyPublisher()
    }

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
            let entry = try await createCjitEntry(
                channelSizeSat: channelSizeSat,
                invoiceSat: invoiceSat,
                invoiceDescription: invoiceDescription,
                nodeId: nodeId,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
            self.stateChangedSubject.send()
            return entry
        }
    }

    func cjitOrders(entryIds: [String]? = nil, filter: CJitStateEnum? = nil, refresh: Bool = true) async throws -> [IcJitEntry] {
        try await ServiceQueue.background(.core) {
            try await getCjitEntries(entryIds: entryIds, filter: filter, refresh: refresh)
        }
    }

    func getCjit(channel: ChannelDetails) async -> IcJitEntry? {
        do {
            let orders = try await cjitOrders()
            return orders.first { order in
                order.channelSizeSat == channel.channelValueSats && order.lspNode.pubkey == channel.counterpartyNodeId
            }
        } catch {
            return nil
        }
    }

    func newOrder(
        lspBalanceSat: UInt64,
        channelExpiryWeeks: UInt32,
        options: CreateOrderOptions
    ) async throws -> IBtOrder {
        try await ServiceQueue.background(.core) {
            let order = try await createOrder(
                lspBalanceSat: lspBalanceSat,
                channelExpiryWeeks: channelExpiryWeeks,
                options: options
            )
            self.stateChangedSubject.send()
            return order
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

    func upsertOrdersList(_ orders: [IBtOrder]) async throws {
        try await ServiceQueue.background(.core) {
            try await upsertOrders(orders: orders)
        }
    }

    func upsertCjitEntriesList(_ cjitEntries: [IcJitEntry]) async throws {
        try await ServiceQueue.background(.core) {
            try await upsertCjitEntries(entries: cjitEntries)
        }
    }

    func setInfo(_ info: IBtInfo) async throws {
        try await ServiceQueue.background(.core) {
            try await upsertInfo(info: info)
        }
    }

    /// Notifies that blocktank state has changed (e.g., after refreshing data)
    func notifyStateChanged() {
        stateChangedSubject.send()
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

    /// Check if an address has been used (has any transactions)
    /// - Parameter address: The Bitcoin address to check
    /// - Returns: true if the address has been used, false otherwise
    func isAddressUsed(address: String) async throws -> Bool {
        return try await ServiceQueue.background(.core) {
            try BitkitCore.isAddressUsed(address: address)
        }
    }

    /// Get balance for a specific address in satoshis
    /// - Parameter address: The Bitcoin address to check
    /// - Returns: The current balance in satoshis
    func getAddressBalance(address: String) async throws -> UInt64 {
        return try await LightningService.shared.getAddressBalance(address: address)
    }

    /// Get balances for multiple addresses
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
                if let balance {
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
            case let .success(value):
                Logger.info("bitkit-core database init: \(value)", context: "CoreService")
            case let .failure(error):
                Logger.error("bitkit-core database init failed: \(error)", context: "CoreService")
            }
        }

        ServiceQueue.background(.core) {
            try await updateBlocktankUrl(newUrl: Env.blocktankClientServer)
        } completion: { result in
            switch result {
            case .success():
                Logger.info("Blocktank URL updated to \(Env.blocktankBaseUrl)", context: "CoreService")
            case let .failure(error):
                Logger.error("Failed to update Blocktank URL: \(error)", context: "CoreService")
            }
        }
    }

    func checkGeoStatus() async throws -> Bool? {
        if !Env.isGeoblockingEnabled {
            return false
        }

        return try await ServiceQueue.background(.core) {
            Logger.info("Checking geo status...", context: "GeoCheck")
            guard let url = URL(string: Env.geoCheckUrl) else {
                Logger.error("Invalid geocheck URL: \(Env.geoCheckUrl)", context: "GeoCheck")
                return nil as Bool?
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
                    return nil as Bool?
                }
            }
            return nil as Bool?
        }
    }
}
