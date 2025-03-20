//
//  BlocktankViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

@MainActor
class BlocktankViewModel: ObservableObject {
    @Published var orders: [IBtOrder]? = nil
    @Published var cJitEntries: [IcJitEntry]? = nil
    @Published var info: IBtInfo? = nil

    @AppStorage("cjitActive") var cjitActive = false
    @Published private(set) var isRefreshing = false

    private let coreService: CoreService
    private let lightningService: LightningService
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init(coreService: CoreService = .shared,
         lightningService: LightningService = .shared)
    {
        self.coreService = coreService
        self.lightningService = lightningService

        Task { try? await refreshInfo() }
        Task { try? await registerDeviceForNotifications() } // Checks if we have a device token that may need to still be registered
        startPolling()
    }

    deinit {
        RunLoop.main.perform { [weak self] in
            Logger.debug("Stopping poll for orders")
            self?.stopPolling()
        }
    }

    private func startPolling() {
        stopPolling()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: Env.blocktankOrderRefreshInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.refreshTask?.cancel()
            self.refreshTask = Task { @MainActor [weak self] in
                guard let self = self else { return }
                try? await self.refreshOrders()
            }
        }

        // Initial refresh
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            try? await self.refreshOrders()
        }
    }

    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refreshInfo() async throws {
        info = try await getInfo(refresh: false) // Instant set cached info to state before refreshing
        info = try await getInfo(refresh: true)
    }

    func refreshOrders() async throws {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        Logger.debug("Refreshing orders...")

        // Sync UI instantly from cache
        orders = try await coreService.blocktank.orders(refresh: false)
        cJitEntries = try await coreService.blocktank.cjitOrders(refresh: false)

        // The update from server
        orders = try await coreService.blocktank.orders(refresh: true)
        cJitEntries = try await coreService.blocktank.cjitOrders(refresh: true)

        Logger.debug("Orders refreshed")
    }

    func refreshOrder(id: String) async throws -> IBtOrder? {
        let refreshedOrders = try await coreService.blocktank.orders(orderIds: [id], refresh: true)
        guard let refreshedOrder = refreshedOrders.first else { return nil }

        // Update the order in the published array if it exists
        if let index = orders?.firstIndex(where: { $0.id == id }) {
            orders?[index] = refreshedOrder
        }

        return refreshedOrder
    }

    func createCjit(amountSats: UInt64, description: String) async throws -> IcJitEntry {
        guard let nodeId = lightningService.nodeId else {
            throw CustomServiceError.nodeNotStarted
        }

        return try await coreService.blocktank.createCjit(
            channelSizeSat: amountSats * 2, // TODO: check this amount default from RN app
            invoiceSat: amountSats,
            invoiceDescription: description,
            nodeId: nodeId,
            channelExpiryWeeks: 2, // TODO: check this amount default from RN app
            options: .init(source: "bitkit-ios", discountCode: nil)
        )
    }

    func createOrder(spendingBalanceSats: UInt64, receivingBalanceSats: UInt64? = nil, channelExpiryWeeks: UInt8 = 6) async throws -> IBtOrder {
        let finalReceivingBalanceSats = receivingBalanceSats ?? (spendingBalanceSats * 2)

        if let btBOptions = info?.options {
            // Validate they're within the limits
            if (spendingBalanceSats + finalReceivingBalanceSats) > btBOptions.maxChannelSizeSat {
                Logger.error("Channel size exceeds maximum: \(spendingBalanceSats + finalReceivingBalanceSats) > \(btBOptions.maxChannelSizeSat)")
                throw CustomServiceError.channelSizeExceedsMaximum
            }
        } else {
            Logger.warn("Has not refreshed Blocktank info yet, skipping validation of limits")
        }

        let options = try await defaultCreateOrderOptions(clientBalanceSat: spendingBalanceSats)

        Logger.debug("Buying channel with lspBalanceSat: \(finalReceivingBalanceSats) and channelExpiryWeeks: \(channelExpiryWeeks) and options: \(options)")

        return try await coreService.blocktank.newOrder(
            lspBalanceSat: finalReceivingBalanceSats,
            channelExpiryWeeks: UInt32(channelExpiryWeeks),
            options: options
        )
    }

    func openChannel(orderId: String) async throws -> IBtOrder {
        let order = try await coreService.blocktank.open(orderId: orderId)

        // Update the order in the published array if it exists
        if let index = orders?.firstIndex(where: { $0.id == orderId }) {
            orders?[index] = order
        }

        return order
    }

    func estimateOrderFee(spendingBalanceSats: UInt64, receivingBalanceSats: UInt64) async throws -> (feeSat: UInt64, networkFeeSat: UInt64, serviceFeeSat: UInt64) {
        let options = try await defaultCreateOrderOptions(clientBalanceSat: spendingBalanceSats)

        let estimate = try await coreService.blocktank.estimateFee(
            lspBalanceSat: receivingBalanceSats,
            channelExpiryWeeks: 6,
            options: options
        )

        return (
            feeSat: estimate.feeSat,
            networkFeeSat: estimate.networkFeeSat,
            serviceFeeSat: estimate.serviceFeeSat
        )
    }

    /// Creates default options for channel creation or fee estimation
    private func defaultCreateOrderOptions(clientBalanceSat: UInt64) async throws -> CreateOrderOptions {
        guard let nodeId = lightningService.nodeId else {
            throw CustomServiceError.nodeNotStarted
        }

        let timestamp = Date().formatted(.iso8601)
        let signature = try await lightningService.sign(message: "channelOpen-\(timestamp)")

        return CreateOrderOptions(
            clientBalanceSat: clientBalanceSat,
            lspNodeId: nil,
            couponCode: "",
            source: "bitkit-ios",
            discountCode: nil,
            zeroConf: true,
            zeroConfPayment: false,
            zeroReserve: true,
            clientNodeId: nodeId,
            signature: signature,
            timestamp: timestamp,
            refundOnchainAddress: nil,
            announceChannel: false
        )
    }

    func registerDeviceForNotifications(force: Bool = false) async throws {
        // Token saved in AppDelegate
        guard let deviceToken = UserDefaults.standard.string(forKey: "deviceToken") else {
            Logger.debug("No device token found yet, skipping notification registration")
            return
        }

        // Check if this token has already been registered (unless force flag is true)
        if !force {
            let lastRegisteredToken = UserDefaults.standard.string(forKey: "lastRegisteredDeviceToken")
            if deviceToken == lastRegisteredToken {
                Logger.debug("Device token already registered with Blocktank, skipping registration")
                return
            }
        }

        guard let nodeId = LightningService.shared.nodeId else {
            throw AppError(serviceError: .nodeNotStarted)
        }

        Logger.info("Registering device for notifications")

        let isoTimestamp = ISO8601DateFormatter().string(from: Date())
        let messageToSign = "bitkit-notifications\(deviceToken)\(isoTimestamp)"

        let signature = try await LightningService.shared.sign(message: messageToSign)

        let keypair = try Crypto.generateKeyPair()

        Logger.debug("Notification encryption public key: \(keypair.publicKey.hex)")

        // New keypair for each token registration
        if try Keychain.exists(key: .pushNotificationPrivateKey) {
            try? Keychain.delete(key: .pushNotificationPrivateKey)
        }

        try Keychain.save(key: .pushNotificationPrivateKey, data: keypair.privateKey)

        let result = try await coreService.blocktank.registerDeviceForNotifications(
            deviceToken: deviceToken,
            publicKey: keypair.publicKey.hex,
            features: Env.pushNotificationFeatures.map { $0.feature },
            nodeId: nodeId,
            isoTimestamp: isoTimestamp,
            signature: signature
        )

        // Save this token as successfully registered
        UserDefaults.standard.setValue(deviceToken, forKey: "lastRegisteredDeviceToken")
        Logger.debug("Device successfully registered for notifications")
    }

    func pushNotificationTest() async throws {
        guard let deviceToken = UserDefaults.standard.string(forKey: "deviceToken") else {
            throw BlocktankError_deprecated.missingDeviceToken
        }

        Logger.debug("Sending test notification to self")

        try await coreService.blocktank.pushNotificationTest(
            deviceToken: deviceToken,
            secretMessage: "hello",
            notificationType: BlocktankNotificationType.orderPaymentConfirmed.rawValue
        )
    }
}
