import Foundation
import LDKNode

// MARK: - Activity Service
class ActivityService {
    private let coreService: CoreService
    
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
            let activities = try getActivities(filter: .all, txType: nil, tags: nil, search: nil, minDate: nil, maxDate: nil, limit: nil, sortDirection: nil)
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
            
            for payment in payments {
                // Skip pending inbound payments, just means they created an invoice
                guard !(payment.status == .pending && payment.direction == .inbound) else { continue }
                
                let state: PaymentState
                switch payment.status {
                case .failed:
                    state = .failed
                case .pending:
                    state = .pending
                case .succeeded:
                    state = .succeeded
                }
                
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
                
                if let _ = try getActivityById(activityId: payment.id) {
                    try updateActivity(activityId: payment.id, activity: .lightning(ln))
                    updatedCount += 1
                } else {
                    try insertActivity(activity: .lightning(ln))
                    addedCount += 1
                }
            }
            
            Logger.info("Synced LDK payments - Added: \(addedCount), Updated: \(updatedCount)", context: "CoreService")
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
    
    #if DEBUG
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
                "Gym membership"
            ]
            
            for i in 0..<count {
                let isLightning = Bool.random()
                let value = UInt64.random(in: 1000...1000000) // Random sats between 1k and 1M
                let timestamp = timestamp - UInt64.random(in: 0...2592000) // Random time in last 30 days
                let txType: PaymentType = Bool.random() ? .sent : .received
                let status: PaymentState = {
                    let random = Int.random(in: 0...10)
                    if random < 8 { return .succeeded } // 80% chance
                    if random < 9 { return .pending } // 10% chance
                    return .failed // 10% chance
                }()
                
                let activity: Activity
                let id: String
                
                if isLightning {
                    id = "test-lightning-\(i)"
                    activity = .lightning(LightningActivity(
                        id: id,
                        txType: txType,
                        status: status,
                        value: value,
                        fee: UInt64.random(in: 1...1000),
                        invoice: "lnbc\(value)",
                        message: possibleMessages.randomElement() ?? "",
                        timestamp: timestamp,
                        preimage: Bool.random() ? "preimage\(i)" : nil,
                        createdAt: timestamp,
                        updatedAt: timestamp
                    ))
                } else {
                    id = "test-onchain-\(i)"
                    activity = .onchain(OnchainActivity(
                        id: id,
                        txType: txType,
                        txId: String(repeating: "a", count: 64), // Mock txid
                        value: value,
                        fee: UInt64.random(in: 100...10000),
                        feeRate: UInt64.random(in: 1...100),
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
                let numTags = Int.random(in: 0...3)
                if numTags > 0 {
                    let tags = Array(Set((0..<numTags).map { _ in possibleTags.randomElement()! }))
                    try await self.appendTag(toActivity: id, tags)
                }
            }
        }
    }
    #endif
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

    func createCjit(
        channelSizeSat: UInt64,
        invoiceSat: UInt64,
        invoiceDescription: String,
        nodeId: String,
        channelExpiryWeeks: UInt32,
        options: CreateCjitOptions
    ) async throws -> IcJitEntry {
        try await ServiceQueue.background(.core) {
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
}

// MARK: - Core Service requires shared init for both activity and blocktank services
class CoreService {
    static let shared = CoreService()
    private let walletIndex: Int
    
    lazy var activity: ActivityService = .init(coreService: self)
    lazy var blocktank: BlocktankService = .init(coreService: self)
    
    private init(walletIndex: Int = 0) {
        self.walletIndex = walletIndex
        
        _ = try! initDb(basePath: Env.bitkitCoreStorage(walletIndex: walletIndex).path)
        
        // First thing ever added to the core queue so guarenteed to run first before any of above functions on the same queue
        ServiceQueue.background(.core, {
            try initDb(basePath: Env.bitkitCoreStorage(walletIndex: walletIndex).path)
        }) { result in
            switch result {
            case .success(let value):
                Logger.info("bitkit-core database init: \(value)", context: "CoreService")
            case .failure(let error):
                Logger.error("bitkit-core database init failed: \(error)", context: "CoreService")
            }
        }
        ServiceQueue.background(.core, {
            try await updateBlocktankUrl(newUrl: Env.blocktankClientServer)
        }) { result in
            switch result {
            case .success():
                Logger.info("Blocktank URL updated to \(Env.blocktankBaseUrl)", context: "CoreService")
            case .failure(let error):
                Logger.error("Failed to update Blocktank URL: \(error)", context: "CoreService")
            }
        }
    }
}
