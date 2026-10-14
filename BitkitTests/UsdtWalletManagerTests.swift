@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class UsdtWalletManagerTests: XCTestCase {
    func testEndpointPublicationOmitsUnavailableUsdtAndPropagatesCancellation() async throws {
        try XCTSkipUnless(Env.isUsdtEnabled)
        let unavailable = UsdtWalletManager(loadCredentials: { throw UsdtError.InvalidCredentials })
        let endpoint = try await unavailable.paymentEndpointForPublishing()
        XCTAssertNil(endpoint)
        let cancelled = UsdtWalletManager(loadCredentials: { throw CancellationError() })
        do {
            _ = try await cancelled.paymentEndpointForPublishing()
            XCTFail("Cancelled endpoint publication must stop")
        } catch is CancellationError {}
    }

    func testHistoryRequestDuringRefreshSurvivesTheBalanceThrottle() async throws {
        try XCTSkipUnless(Env.isUsdtEnabled)
        let entered = expectation(description: "refresh started")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        var attempts = 0
        let manager = UsdtWalletManager(loadCredentials: {
            attempts += 1
            if attempts == 1 {
                entered.fulfill()
                for await _ in gate.stream {
                    break
                }
            }
            throw UsdtError.InvalidCredentials
        })
        let refresh = Task { await manager.refresh() }
        await fulfillment(of: [entered], timeout: 2)
        await manager.refresh(includeHistory: true)
        gate.continuation.yield(())
        await refresh.value
        await manager.refresh()
        XCTAssertEqual(attempts, 2)
    }

    func testUsdCentsUseTheLocalesDecimalAndGroupingSeparators() {
        XCTAssertEqual("1000000".formattedUsdCents(locale: Locale(identifier: "en_US")), "$10,000.00")
        XCTAssertEqual("1000000".formattedUsdCents(locale: Locale(identifier: "de_DE")), "$10.000,00")
        XCTAssertEqual("5".formattedUsdCents(locale: Locale(identifier: "de_DE")), "$0,05")
        XCTAssertEqual("invalid".formattedUsdCents(locale: Locale(identifier: "en_US")), "—")
    }

    func testUsdtEndpointPayloadUsesCanonicalKeyOrder() throws {
        let address = "0x18503bD685aF84E6A7bC289898bAa1C3f5d8527E"
        let endpoint = try PaykitUsdt.endpoint(address: address)
        XCTAssertEqual(endpoint.rawPayload, "{\"chain_id\":\"42161\",\"token\":\"\(PaykitUsdt.token)\",\"value\":\"\(address)\"}")
        XCTAssertEqual(PaykitUsdt.address(from: endpoint.rawPayload), address)
    }

    func testChangingUsdtPreferencePublishesForOpenPaymentAndAuthorizationViews() {
        let settings = SettingsViewModel.shared
        let original = settings.usdtPreference
        defer { settings.usdtPreference = original }
        settings.usdtPreference = .disabled
        var changes = 0
        let observation = settings.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        settings.usdtPreference = .enabled
        XCTAssertGreaterThan(changes, 0)
        XCTAssertTrue(settings.isUsdtEnabled)
    }

    func testRestoredFundsAndPendingTransfersKeepUsdtEnabledAcrossFeatures() {
        let settings = SettingsViewModel.shared
        let original = settings.usdtPreference
        defer { settings.usdtPreference = original }
        for preference: UsdtPreference in [.undecided, .disabled] {
            settings.usdtPreference = preference
            settings.protectUsdtFunds(UsdtPreference.hasFundsOrPendingTransfers(balance: 0, transfers: []))
            XCTAssertEqual(settings.usdtPreference, preference)
            for (balance, transfers): (UInt64, [UsdtTransfer]) in [
                (1, []), (0, [transfer("pending", status: .pending)]), (0, [transfer("bridge", status: .bridging)]),
            ] {
                settings.usdtPreference = preference
                settings.protectUsdtFunds(UsdtPreference.hasFundsOrPendingTransfers(balance: balance, transfers: transfers))
                XCTAssertTrue(settings.isUsdtEnabled)
                XCTAssertTrue(UsdtPreference.isEnabled())
                settings.protectUsdtFunds(false)
                XCTAssertTrue(settings.isUsdtEnabled, "Draining funds must not silently turn off an enabled wallet")
            }
        }
    }

    func testUnknownBalancePreservesDisabledPreferenceWhileKeepingHistoryVisible() {
        let settings = SettingsViewModel.shared
        let original = settings.usdtPreference
        defer { settings.usdtPreference = original }
        settings.usdtPreference = .disabled
        let history = [transfer("completed")]
        XCTAssertTrue(UsdtPreference.protectsFunds(balance: nil, transfers: history))
        for balance: UInt64? in [nil, 0] {
            settings.protectUsdtFunds(UsdtPreference.hasFundsOrPendingTransfers(balance: balance, transfers: history))
            XCTAssertEqual(settings.usdtPreference, .disabled)
            XCTAssertFalse(PublicPaykitService.isUsdtPaymentOptionEnabled())
        }
    }

    func testKnownInboundPaymentsProtectTheWalletUntilEachSettles() {
        let manager = UsdtWalletManager(loadCredentials: { throw CancellationError() })
        let settings = SettingsViewModel.shared
        let original = settings.usdtPreference
        defer { settings.usdtPreference = original }
        settings.usdtPreference = .disabled
        manager.recordDepositStatus(id: "waiting", status: "awaiting_deposit")
        XCTAssertFalse(manager.hasProtectedFunds)
        manager.recordDepositStatus(id: "first", status: "funded")
        settings.protectUsdtFunds(manager.hasFundsOrPendingTransfers)
        XCTAssertTrue(settings.isUsdtEnabled)
        manager.recordDepositStatus(id: "second", status: "refunding")
        manager.recordDepositStatus(id: "first", status: "completed")
        XCTAssertTrue(manager.hasProtectedFunds)
        manager.recordDepositStatus(id: "second", status: "refunded")
        XCTAssertFalse(manager.hasProtectedFunds)
        XCTAssertTrue(settings.isUsdtEnabled)
    }

    func testUsdtOptInDoesNotImplicitlyPublishOrHideExistingFunds() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        XCTAssertFalse(UsdtPreference.isEnabled(defaults: defaults))
        XCTAssertFalse(PublicPaykitService.isUsdtPaymentOptionEnabled(defaults: defaults))
        defaults.set(UsdtPreference.disabled.rawValue, forKey: UsdtPreference.key)
        XCTAssertFalse(UsdtPreference.isEnabled(defaults: defaults))
        XCTAssertTrue(UsdtPreference.protectsFunds(balance: 1, transfers: []))
        for status: UsdtTransferStatus in [.pending, .bridging, .bridgeNeedsAttention, .bridgeFailed] {
            XCTAssertTrue(UsdtPreference.protectsFunds(balance: 0, transfers: [transfer("pending", status: status)]))
        }
        XCTAssertFalse(UsdtPreference.protectsFunds(balance: 0, transfers: [transfer("completed")]))
        XCTAssertTrue(UsdtPreference.protectsFunds(balance: nil, transfers: [transfer("completed")]))
        XCTAssertFalse(UsdtPreference.isEnabled(defaults: defaults))
        defaults.set(UsdtPreference.enabled.rawValue, forKey: UsdtPreference.key)
        XCTAssertTrue(UsdtPreference.isEnabled(defaults: defaults))
        XCTAssertEqual(PublicPaykitService.isUsdtPaymentOptionEnabled(defaults: defaults), Env.isUsdtEnabled)
        defaults.set(false, forKey: PublicPaykitService.usdtPaymentOptionEnabledKey)
        XCTAssertFalse(PublicPaykitService.isUsdtPaymentOptionEnabled(defaults: defaults))
    }

    func testUnresolvedBridgeDepositsPreventDisablingUsdt() {
        for status in ["held", "processing", "refunding", "refund_requested", "failed", "unknown"] {
            XCTAssertTrue(UsdtPreference.hasPendingDeposit(status), status)
        }
        for status in ["completed", "refunded", "waiting", "awaiting_deposit", "expired"] {
            XCTAssertFalse(UsdtPreference.hasPendingDeposit(status), status)
        }
    }

    func testBridgeCostErrorsAskForALargerAmountWithoutInventingAMinimum() {
        let error = UsdtError.BridgeAmountTooSmall
        XCTAssertEqual(UsdtWalletManager.message(for: error), t("usdt__error_bridge_amount"))
        XCTAssertEqual(usdtDepositAmountMessage(error, amount: "3.5"), t("usdt__error_bridge_amount"))
        XCTAssertEqual(usdtDepositAmountMessage(UsdtError.DepositAmountOutOfRange(minUsdCents: "200", maxUsdCents: nil), amount: "1"),
                       t("usdt__deposit_minimum", variables: ["amount": "200".usdCents]))
    }

    func testOwnAddressHasSpecificErrorForExactAndMaximumSends() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = UsdtWalletManager(storageDirectory: directory, loadCredentials: {
            ("test test test test test test test test test test test junk", nil)
        })
        _ = try await manager.paymentEndpoint()
        let recipient = " \(manager.address.lowercased()) "
        do {
            _ = try await manager.quote(recipient: recipient, amount: "1", destination: .arbitrum)
            XCTFail("Self-send must be rejected before requesting a quote")
        } catch {
            XCTAssertEqual(error as? UsdtWalletError, .selfSend)
            XCTAssertEqual(UsdtWalletManager.message(for: error), t("usdt__error_self_send"))
        }
        do {
            _ = try await manager.quoteMaximum(recipient: recipient, destination: .arbitrum)
            XCTFail("Maximum self-send must be rejected before requesting a quote")
        } catch {
            XCTAssertEqual(error as? UsdtWalletError, .selfSend)
        }
        XCTAssertEqual(UsdtWalletManager.message(for: UsdtError.InvalidAddress), t("usdt__error_address"))
    }

    func testNativeSubmissionRejectsAnExpiredPreciseDeadlineWithoutCreatingATransfer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = try UsdtWallet(
            address: "0x1111111111111111111111111111111111111111",
            storagePath: directory.appendingPathComponent("usdt.sqlite").path,
            rpcUrl: "http://127.0.0.1:1", bundlerUrl: "http://127.0.0.1:1", bridgeUrl: nil,
            backup: UnavailableUsdtBackup()
        )
        let deadline = try XCTUnwrap(PaykitPreciseInstant(timestamp: "2020-01-01T00:00:00.123456789Z"))
        do {
            _ = try await wallet.sendWithDeadline(
                quoteId: "expired-request", mnemonic: "test test test test test test test test test test test junk",
                passphrase: nil, submissionDeadline: deadline.timestamp
            )
            XCTFail("An expired payment must not be submitted")
        } catch {
            guard let error = error as? UsdtError, case .SubmissionDeadlineExpired = error else { throw error }
            XCTAssertEqual(UsdtWalletManager.message(for: error), t("wallet__payment_request_expired"))
        }
        XCTAssertTrue(try wallet.history().isEmpty)
    }

    func testFeeCollectionFailureIsActionableWithoutMisclassifyingOtherRejections() {
        XCTAssertEqual(UsdtWalletManager.message(for: UsdtError.TransactionRejected(reason: "Paymaster fee collection failed")),
                       t("usdt__error_fee_collection"))
        XCTAssertEqual(UsdtWalletManager.message(for: UsdtError.TransactionRejected(reason: "Provider rejected the request")),
                       t("usdt__error_rejected"))
        XCTAssertEqual(UsdtWalletManager.message(for: UsdtError.InsufficientBalance), t("usdt__error_balance"))
    }

    func testOnlyNewConfirmedReceiptsCelebrateAfterInitialSync() {
        let old = transfer("old")
        let incoming = transfer("new")
        let pending = transfer("pending", status: .pending)
        let failed = transfer("failed", status: .failed)
        let outgoing = transfer("sent", incoming: false)
        let empty = transfer("zero", amount: 0)
        XCTAssertTrue(UsdtWalletManager.newIncomingTransfers(previous: nil, current: [old]).isEmpty)
        let current = [old, incoming, pending, failed, outgoing, empty]
        XCTAssertEqual(UsdtWalletManager.newIncomingTransfers(previous: [old], current: current), [incoming])
        XCTAssertTrue(UsdtWalletManager.newIncomingTransfers(previous: current, current: current).isEmpty)
        let confirmed = transfer("pending")
        XCTAssertEqual(UsdtWalletManager.newIncomingTransfers(previous: current, current: current + [confirmed]), [confirmed])
    }

    func testLinkedOrderStatusAndErrorSupersedeDepositStateTogether() {
        let deposit = UsdtDeposit(id: "deposit", network: "solana", asset: "USDT", amount: 100, sourceTx: "tx", status: "held",
                                  code: "standing_route_unavailable", refundTx: nil)
        let cases: [(String?, String?, String)] = [
            ("completed", nil, "usdt__confirmed"),
            (nil, deposit.code, "usdt__deposit_needs_attention"),
            ("unknown", nil, "usdt__deposit_needs_attention"),
            ("pending", nil, "usdt__pending"),
            ("processing", nil, "usdt__pending"),
            ("refunded", nil, "usdt__deposit_refunded"),
            ("failed", "order_error", "usdt__deposit_needs_attention"),
        ]
        for (status, code, key) in cases {
            let order = status.map { UsdtDepositOrder(status: $0, amountIn: 100, amountOut: 90, destinationTx: nil, refundTx: nil, code: code) }
            let detail = UsdtDepositDetail(deposit: deposit, order: order)
            XCTAssertEqual(detail.statusText, t(key))
            XCTAssertEqual(detail.statusCode, code)
        }
    }

    func testDepositStatusDistinguishesRefundProgressFromActionableErrors() {
        let cases: [(String, String?, String)] = [
            ("completed", "standing_route_unavailable", "usdt__confirmed"),
            ("refunded", "xchain_amount_too_small", "usdt__deposit_refunded"),
            ("refund_requested", "standing_refund_pending", "usdt__deposit_refunding"),
            ("refunding", "standing_refund_pending", "usdt__deposit_refunding"),
            ("refund_requested", "standing_tron_refund_requires_operator", "usdt__deposit_needs_attention"),
            ("refunding", "refund_error", "usdt__deposit_needs_attention"),
            ("funded", nil, "usdt__pending"),
            ("confirming", nil, "usdt__pending"),
            ("swapping", nil, "usdt__pending"),
            ("bridging", nil, "usdt__pending"),
            ("delivering", nil, "usdt__pending"),
            ("swapping", "order_error", "usdt__deposit_needs_attention"),
            ("pending", "standing_route_unavailable", "usdt__deposit_needs_attention"),
            ("below_minimum", "xchain_amount_too_small", "usdt__deposit_needs_attention"),
        ]
        for (status, code, key) in cases {
            let deposit = UsdtDeposit(id: "deposit", network: "bsc", asset: "USDT", amount: 100, sourceTx: "tx", status: status,
                                      code: code, refundTx: nil)
            let order = UsdtDepositOrder(status: status, amountIn: 100, amountOut: 90, destinationTx: nil, refundTx: nil, code: code)
            for linkedOrder in [nil, order] {
                let detail = UsdtDepositDetail(deposit: deposit, order: linkedOrder)
                XCTAssertEqual(detail.statusText, t(key), status)
                XCTAssertEqual(detail.statusCode, code, status)
            }
        }
    }

    func testDepositRefundEligibilityUsesCurrentOrderAndSupportedAsset() {
        let deposit = UsdtDeposit(id: "deposit", network: "bsc", asset: "USDT", amount: 50_000_001,
                                  sourceTx: "source-tx", status: "held", code: nil, refundTx: nil)
        var detail = UsdtDepositDetail(deposit: deposit, order: nil)
        XCTAssertTrue(detail.canRequestRefund)
        for status in ["completed", "refunded", "refunding", "refund_requested"] {
            detail.order = UsdtDepositOrder(status: status, amountIn: nil, amountOut: nil, destinationTx: nil, refundTx: nil, code: nil)
            XCTAssertFalse(detail.canRequestRefund, status)
        }
        detail.order = nil
        detail.deposit.asset = "ETH"
        XCTAssertFalse(detail.canRequestRefund)
        detail.deposit.asset = "USDT"
        detail.deposit.network = "unsupported"
        XCTAssertFalse(detail.canRequestRefund)
    }

    func testRefundConfirmationShowsLocalizedAmountNetworkAndFullAddress() {
        let address = "0x1111222233334444555566667777888899990000"
        let deposit = UsdtDeposit(id: "deposit", network: "bsc", asset: "USDT", amount: 50_000_001,
                                  sourceTx: "source-tx", status: "held", code: nil, refundTx: nil)
        let detail = UsdtDepositDetail(deposit: deposit, order: nil)
        for (identifier, amount) in [("en_US", "50.00"), ("de_DE", "50,00")] {
            let confirmation = detail.refundConfirmation(address: address, hideBalance: false, locale: Locale(identifier: identifier))
            for value in [amount, "BNB Smart Chain (BSC)", address, "Refund fees may apply."] {
                XCTAssertTrue(confirmation.contains(value), value)
            }
            XCTAssertFalse(confirmation.contains("50.000001"))
        }
        let hidden = detail.refundConfirmation(address: address, hideBalance: true, locale: Locale(identifier: "en_US"))
        XCTAssertFalse(hidden.contains("50.00"))
        XCTAssertTrue(hidden.contains("• • • • •"))
        XCTAssertTrue(hidden.contains(address))
        XCTAssertEqual(deposit.networkLabel, "BNB Smart Chain")
        XCTAssertEqual(deposit.refundNetworkLabel, "BSC")
    }

    func testIncomingCelebrationsWaitUntilPresentationIsAvailable() {
        var receipts = UsdtReceiptQueue()
        let sheets = SheetViewModel()
        let first = transfer("first")
        let second = transfer("second")

        // Bitcoin and Lightning receipts share the same presentation.
        sheets.showSheet(.receivedTx)
        receipts.didPresent()
        receipts.append(first)
        receipts.append(first)
        receipts.append(second)

        XCTAssertNil(receipts.takeNext(canPresent: false))

        sheets.receivedTxSheetItem = nil
        XCTAssertNil(receipts.takeNext(canPresent: !sheets.isAnySheetOpen))
        sheets.hideSheetIfActive(.receivedTx)
        receipts.didDismiss()

        XCTAssertEqual(receipts.takeNext(canPresent: true), first)
        sheets.showSheet(.receivedTx)
        XCTAssertNil(receipts.takeNext(canPresent: false))

        // SwiftUI clears the binding before the sheet's dismissal animation finishes.
        sheets.receivedTxSheetItem = nil
        XCTAssertNil(receipts.takeNext(canPresent: !sheets.isAnySheetOpen))
        sheets.hideSheetIfActive(.receivedTx)
        receipts.didDismiss()

        XCTAssertEqual(receipts.takeNext(canPresent: true), second)
        sheets.showSheet(.receivedTx)
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .receivedTx)
        sheets.hideSheetIfActive(.receivedTx)
        receipts.didDismiss()
        XCTAssertNil(receipts.takeNext(canPresent: true))
    }

    func testIncomingCelebrationReplacesReceiveAndDoesNotRepeatOnDismiss() async throws {
        var receipts = UsdtReceiptQueue()
        let sheets = SheetViewModel()
        let received = transfer("received")
        sheets.showSheet(.receive)
        receipts.append(received)

        let next = try XCTUnwrap(receipts.takeNext(canPresent: sheets.canPresentReceivedTx))
        sheets.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .onchain, usdtAmount: next.amount, usdtTransferId: next.id))
        XCTAssertTrue(sheets.isReplacingSheet)
        XCTAssertFalse(sheets.canPresentReceivedTx)
        XCTAssertNil(receipts.takeNext(canPresent: sheets.canPresentReceivedTx))

        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .receivedTx)
        XCTAssertEqual((sheets.activeSheetConfiguration?.data as? ReceivedTxSheetDetails)?.usdtTransferId, received.id)
        sheets.hideSheetIfActive(.receivedTx)
        receipts.didDismiss()
        XCTAssertNil(receipts.takeNext(canPresent: sheets.canPresentReceivedTx))
    }

    private func transfer(_ id: String, incoming: Bool = true, status: UsdtTransferStatus = .confirmed, amount: UInt64 = 1_000_000) -> UsdtTransfer {
        UsdtTransfer(
            sender: nil,
            id: id,
            txHash: status == .pending ? nil : id,
            userOperationHash: nil,
            bridgeGuid: nil,
            orchestra: nil,
            recipient: "recipient",
            destination: .arbitrum,
            amount: amount,
            receivedAmount: amount,
            fee: nil,
            isIncoming: incoming,
            status: status,
            timestamp: 1
        )
    }

    func testWalletReadsCredentialsOncePerSessionAndUsesFreshCredentialsAfterWipe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mnemonic = "test test test test test test test test test test test junk"
        var credentialReads = 0
        let manager = UsdtWalletManager(storageDirectory: directory, loadCredentials: {
            credentialReads += 1
            return (mnemonic, nil)
        })
        async let first = manager.paymentEndpoint()
        async let second = manager.paymentEndpoint()
        let (firstEndpoint, secondEndpoint) = try await (first, second)
        XCTAssertEqual(firstEndpoint.value, secondEndpoint.value)
        _ = try await manager.storedTransfer("missing")
        let snapshot = try await manager.backupSnapshot()
        let backup = try XCTUnwrap(snapshot)
        manager.recordDepositStatus(id: "old-deposit", status: "funded")
        XCTAssertTrue(manager.hasProtectedFunds)
        try await manager.restoreBackup(backup)
        XCTAssertFalse(manager.hasProtectedFunds)
        XCTAssertEqual(credentialReads, 1)

        manager.recordDepositStatus(id: "old-deposit", status: "funded")
        try await manager.wipe()
        manager.recordDepositStatus(id: "late-response", status: "funded")
        XCTAssertFalse(manager.hasProtectedFunds)
        do {
            _ = try await manager.paymentEndpoint()
            XCTFail("A wiped session must not read credentials or reopen its wallet")
        } catch is CancellationError {}
        XCTAssertEqual(credentialReads, 1)

        let restored = UsdtWalletManager(storageDirectory: directory, loadCredentials: {
            credentialReads += 1
            return (mnemonic, "restored passphrase")
        })
        let restoredEndpoint = try await restored.paymentEndpoint()
        XCTAssertNotEqual(restoredEndpoint.value, firstEndpoint.value)
        XCTAssertEqual(credentialReads, 2)
        try await restored.wipe()
    }

    func testWipeRemovesUsdtPersistenceAndStopsSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let usdtFiles = ["usdt-wipe-test.sqlite", "usdt-wipe-test.sqlite-wal", "usdt-wipe-test.sqlite-shm"]
            .map { directory.appendingPathComponent($0) }
        let unrelated = directory.appendingPathComponent("unrelated-wipe-test.txt")
        defer { try? FileManager.default.removeItem(at: unrelated) }
        for file in usdtFiles + [unrelated] {
            try Data("private payment data".utf8).write(to: file)
        }

        let initializationStarted = expectation(description: "credential read started")
        var resumeInitialization: CheckedContinuation<Void, Never>?
        let manager = UsdtWalletManager(storageDirectory: directory, loadCredentials: {
            await withCheckedContinuation { continuation in
                resumeInitialization = continuation
                initializationStarted.fulfill()
            }
            return ("test test test test test test test test test test test junk", nil)
        })
        let endpoint = Task { try await manager.paymentEndpoint() }
        await fulfillment(of: [initializationStarted], timeout: 2)
        let wipeStarted = expectation(description: "wipe started during initialization")
        let first = Task {
            wipeStarted.fulfill()
            try await manager.wipe()
        }
        await fulfillment(of: [wipeStarted], timeout: 2)
        do {
            _ = try await manager.paymentEndpoint()
            XCTFail("A wipe must block further wallet operations")
        } catch is CancellationError {}
        let second = Task { try await manager.wipe() }
        resumeInitialization?.resume()
        _ = try await endpoint.value
        _ = try await (first.value, second.value)
        for file in usdtFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [unrelated.lastPathComponent])
        XCTAssertTrue(manager.address.isEmpty)
        XCTAssertTrue(manager.transfers.isEmpty)
        XCTAssertNil(manager.balance)
        do {
            _ = try await manager.quote(recipient: "0x1111111111111111111111111111111111111111", amount: "1", destination: .arbitrum)
            XCTFail("A wiped session must not reopen its wallet")
        } catch is CancellationError {}
    }
}

private final class UnavailableUsdtBackup: UsdtBackup {
    func persist(snapshot _: String) async throws {
        throw UsdtError.BackupUnavailable
    }
}
