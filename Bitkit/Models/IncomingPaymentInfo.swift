import Foundation

/// Represents an incoming payment notification that needs to be processed by the app.
/// This is saved by the notification service extension and picked up by the main app when it becomes active.
struct IncomingPaymentInfo: Codable, Equatable {
    /// The type of incoming payment notification
    enum PaymentType: String, Codable {
        case incomingHtlc
        case cjitPaymentArrived
        case orderPaymentConfirmed
        case mutualClose
        case wakeToTimeout
        case unknown

        init(from blocktankType: String) {
            self = PaymentType(rawValue: blocktankType) ?? .unknown
        }
    }

    /// Current processing state of the incoming payment
    enum ProcessingState: String, Codable {
        case pending // Waiting for user to open app
        case processing // App is processing (node starting, connecting peer, etc.)
        case completed // Payment successfully received
        case expired // Payment window expired
        case failed // Processing failed
    }

    let id: String
    let paymentType: PaymentType
    let paymentHash: String?
    let orderId: String?
    let lspId: String?
    let amountMsat: UInt64?
    let receivedAt: Date
    let expiresAt: Date
    var state: ProcessingState

    /// Human-readable description for the notification
    var notificationTitle: String {
        switch paymentType {
        case .incomingHtlc, .cjitPaymentArrived:
            return "Incoming Payment"
        case .orderPaymentConfirmed:
            return "Spending Balance Ready"
        case .mutualClose:
            return "Channel Closing"
        case .wakeToTimeout:
            return "Payment Pending"
        case .unknown:
            return "Notification"
        }
    }

    /// Urgency message for the notification body
    var notificationBody: String {
        switch paymentType {
        case .incomingHtlc, .cjitPaymentArrived:
            return "Open Bitkit now to receive your payment"
        case .orderPaymentConfirmed:
            return "Open Bitkit now to complete setup"
        case .mutualClose:
            return "Your spending balance is being transferred"
        case .wakeToTimeout:
            return "Open Bitkit to process pending payment"
        case .unknown:
            return "Open Bitkit to continue"
        }
    }

    /// Default expiry duration for incoming payments (2 minutes)
    /// This accounts for HTLC timeout constraints
    static let defaultExpiryDuration: TimeInterval = 2 * 60

    /// Storage key for app group UserDefaults
    private static let storageKey = "incomingPaymentInfo"

    /// App group UserDefaults for sharing between app and extension
    private static let appGroupUserDefaults = UserDefaults(suiteName: "group.bitkit")

    /// Creates a new incoming payment info with auto-generated ID and expiry
    init(
        paymentType: PaymentType,
        paymentHash: String? = nil,
        orderId: String? = nil,
        lspId: String? = nil,
        amountMsat: UInt64? = nil,
        expiryDuration: TimeInterval = IncomingPaymentInfo.defaultExpiryDuration
    ) {
        self.id = UUID().uuidString
        self.paymentType = paymentType
        self.paymentHash = paymentHash
        self.orderId = orderId
        self.lspId = lspId
        self.amountMsat = amountMsat
        self.receivedAt = Date()
        self.expiresAt = Date().addingTimeInterval(expiryDuration)
        self.state = .pending
    }

    /// Whether this payment has expired
    var isExpired: Bool {
        Date() > expiresAt
    }

    /// Time remaining until expiry in seconds
    var timeRemaining: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }

    // MARK: - Persistence

    /// Saves the incoming payment info to shared storage
    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(self)
            Self.appGroupUserDefaults?.set(data, forKey: Self.storageKey)
            Self.appGroupUserDefaults?.synchronize()
        } catch {
            // Note: Logger may not be available in extension, use os_log
            print("IncomingPaymentInfo: Failed to save: \(error)")
        }
    }

    /// Loads the incoming payment info from shared storage
    static func load() -> IncomingPaymentInfo? {
        guard let data = appGroupUserDefaults?.data(forKey: storageKey) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var info = try decoder.decode(IncomingPaymentInfo.self, from: data)

            // Update state if expired
            if info.isExpired && info.state == .pending {
                info.state = .expired
                info.save()
            }

            return info
        } catch {
            print("IncomingPaymentInfo: Failed to load: \(error)")
            return nil
        }
    }

    /// Clears the incoming payment info from shared storage
    static func clear() {
        appGroupUserDefaults?.removeObject(forKey: storageKey)
        appGroupUserDefaults?.synchronize()
    }

    /// Updates the state and saves
    mutating func updateState(_ newState: ProcessingState) {
        state = newState
        save()
    }
}
