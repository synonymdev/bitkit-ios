@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

@MainActor
final class QuickPayPaymentCoordinatorTests: XCTestCase {
    private let settings = SettingsViewModel.shared
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: QuickPaySpendStore!
    private let rates = QuickPaySpendRates(
        satsToUsdCents: { sats in Int64(sats) / 2 },
        usdToSats: { usd in UInt64(usd * 200) }
    )

    override func setUp() {
        super.setUp()
        // Building a `CurrencyViewModel` syncs the display currency into the shared group.bitkit
        // suite from its initializer, which the widget extension reads.
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        // Snapshot from disk rather than from `SettingsViewModel.shared`: its `@AppStorage` properties
        // do not observe `setPersistentDomain`, so after an earlier suite's `resetToDefaults()` the
        // singleton still reports the defaults, and writing those back in tearDown landed on top of
        // the snapshot's restore.
        snapshotAppDefaults(
            "primaryDisplay",
            "cached_fx_rates",
            "enableQuickpay",
            "quickpayAmount",
            "quickpayDailyLimitMultiplier"
        )
        suiteName = "QuickPayPaymentCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = QuickPaySpendStore(defaults: defaults, dayKey: { "2026-08-15" })
        settings.enableQuickpay = true
        settings.quickpayAmount = 5
        settings.quickpayDailyLimitMultiplier = 5
        guard let encodedRates = try? JSONEncoder().encode([usdRate]) else {
            XCTFail("Failed to encode the QuickPay test exchange rate")
            return
        }
        UserDefaults.standard.set(encodedRates, forKey: "cached_fx_rates")
    }

    override func tearDown() {
        // No settings restored here: teardown blocks run first, so this would overwrite the restore.
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    func testDuplicatePaymentIsNotHardReject() {
        XCTAssertFalse(QuickPayPaymentCoordinator.isHardReject(NodeError.DuplicatePayment(message: "dup")))
    }

    func testInvalidInvoiceIsHardReject() {
        XCTAssertTrue(QuickPayPaymentCoordinator.isHardReject(NodeError.InvalidInvoice(message: "bad")))
    }

    func testPersistenceIsNotHardReject() {
        XCTAssertFalse(QuickPayPaymentCoordinator.isHardReject(NodeError.PersistenceFailed(message: "io")))
    }

    func testWrappedInvalidInvoiceIsHardReject() {
        XCTAssertTrue(QuickPayPaymentCoordinator.isHardReject(Bitkit.AppError(error: NodeError.InvalidInvoice(message: "bad"))))
    }

    func testWrappedDuplicatePaymentIsDuplicateNotHardReject() {
        let wrapped = Bitkit.AppError(error: NodeError.DuplicatePayment(message: "dup"))
        XCTAssertTrue(QuickPayPaymentCoordinator.isDuplicatePayment(wrapped))
        XCTAssertFalse(QuickPayPaymentCoordinator.isHardReject(wrapped))
    }

    func testQuickPayHandlingTracksExactHashUntilReset() {
        let app = AppViewModel()
        app.beginQuickPay(paymentHash: "active")

        XCTAssertTrue(app.isQuickPayHandling(paymentHash: "active"))
        XCTAssertFalse(app.isQuickPayHandling(paymentHash: "other"))

        app.resetQuickPay()
        XCTAssertFalse(app.isQuickPayHandling(paymentHash: "active"))
    }

    func testWrappedPersistenceIsNotHardReject() {
        XCTAssertFalse(QuickPayPaymentCoordinator.isHardReject(Bitkit.AppError(error: NodeError.PersistenceFailed(message: "io"))))
    }

    func testWrappedHardRejectReleasesSpendAndFails() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw Bitkit.AppError(error: NodeError.InvalidInvoice(message: "bad"))
            }
        )

        guard case .failure = route else {
            return XCTFail("Expected failure, got \(String(describing: route))")
        }
        XCTAssertNil(store.record(matching: invoiceHash))
        XCTAssertEqual(store.spentCentsToday(), 0)
    }

    func testSparkRefusalReleasesSpendAndFails() async throws {
        let invoiceHash = try Self.invoiceHash
        // Spark refuses only before anything leaves the wallet, as when its balance can't cover the payment.
        let route = await firstRoute(
            sendBolt11: { _ in
                throw Bitkit.ChannelFreeRailSendRefused(reason: "Spark balance can't cover the payment")
            }
        )

        guard case .failure = route else {
            return XCTFail("Expected failure, got \(String(describing: route))")
        }
        XCTAssertNil(store.record(matching: invoiceHash))
        XCTAssertEqual(store.spentCentsToday(), 0)
    }

    func testWrappedDuplicateDispatchWithSucceededLdkReleasesFreshReserveAndFails() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw Bitkit.AppError(error: NodeError.DuplicatePayment(message: "dup"))
            },
            listRows: {
                [
                    QuickPayReconcileRow(
                        paymentId: "pid",
                        invoicePaymentHash: invoiceHash,
                        isOutboundBolt11: true,
                        status: .succeeded
                    ),
                ]
            }
        )

        guard case .failure = route else {
            return XCTFail("Expected failure, got \(String(describing: route))")
        }
        XCTAssertNil(store.record(matching: invoiceHash))
        XCTAssertEqual(store.spentCentsToday(), 0)
    }

    func testLeftoverRecordGoesPendingWithoutSending() async throws {
        let invoiceHash = try Self.invoiceHash
        var sent = false
        XCTAssertNotNil(
            try store.reserveBound(
                paymentHash: invoiceHash,
                amountSats: 1000,
                enabled: true,
                thresholdUsd: 5,
                multiplier: 5,
                rates: rates
            )
        )

        let route = await firstRoute(
            sendBolt11: { _ in
                sent = true
                return invoiceHash
            }
        )

        XCTAssertFalse(sent)
        guard case let .pending(paymentHash, retryRoute, _, _) = route else {
            return XCTFail("Expected pending, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentHash, invoiceHash)
        XCTAssertEqual(retryRoute, .quickpay)
        XCTAssertNotNil(store.record(matching: invoiceHash))
    }

    func testSendAfterSignalCompletionGoesToSuccess() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { [store] _ in
                store?.signalCompletion(paymentId: nil, paymentHash: invoiceHash, success: true)
                return invoiceHash
            }
        )

        guard case let .success(paymentId, _) = route else {
            return XCTFail("Expected success, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentId, invoiceHash)
        XCTAssertNil(store.record(matching: invoiceHash))
    }

    func testCompleteSuccessAppliesRoutingFee() async throws {
        let invoiceHash = try Self.invoiceHash
        let wallet = WalletViewModel()
        let holder = CoordinatorHolder()
        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { _ in
                _ = holder.coordinator?.complete(
                    paymentId: nil,
                    paymentHash: invoiceHash,
                    success: true,
                    feePaidMsat: 12000
                )
                return invoiceHash
            },
            listRows: { [] }
        )
        holder.coordinator = coordinator

        let route = await firstRoute(from: coordinator, wallet: wallet)
        guard case .success = route else {
            return XCTFail("Expected success, got \(String(describing: route))")
        }
        XCTAssertEqual(wallet.sendAmountSats, 1012)
    }

    func testCompleteFailureAfterSendGoesToFailure() async throws {
        let invoiceHash = try Self.invoiceHash
        let holder = CoordinatorHolder()
        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { _ in
                _ = holder.coordinator?.complete(
                    paymentId: nil,
                    paymentHash: invoiceHash,
                    success: false
                )
                return invoiceHash
            },
            listRows: { [] }
        )
        holder.coordinator = coordinator

        let route = await firstRoute(from: coordinator)
        guard case .failure = route else {
            return XCTFail("Expected failure, got \(String(describing: route))")
        }
    }

    func testAmbiguousDispatchWithOpenRecordGoesPending() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw NodeError.PersistenceFailed(message: "io")
            }
        )

        guard case let .pending(paymentHash, retryRoute, _, _) = route else {
            return XCTFail("Expected pending, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentHash, invoiceHash)
        XCTAssertEqual(retryRoute, .quickpay)
        XCTAssertNotNil(store.record(matching: invoiceHash))
    }

    func testAmbiguousDispatchWithFailedRowGoesToFailure() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw NodeError.PersistenceFailed(message: "io")
            },
            listRows: {
                [
                    QuickPayReconcileRow(
                        paymentId: "pid",
                        invoicePaymentHash: invoiceHash,
                        isOutboundBolt11: true,
                        status: .failed
                    ),
                ]
            }
        )

        guard case .failure = route else {
            return XCTFail("Expected failure, got \(String(describing: route))")
        }
        XCTAssertNil(store.record(matching: invoiceHash))
    }

    func testDuplicateDispatchWithOpenRecordGoesPending() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw NodeError.DuplicatePayment(message: "dup")
            }
        )

        guard case let .pending(paymentHash, retryRoute, _, _) = route else {
            return XCTFail("Expected pending, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentHash, invoiceHash)
        XCTAssertEqual(retryRoute, .quickpay)
        XCTAssertNotNil(store.record(matching: invoiceHash))
        XCTAssertGreaterThan(store.spentCentsToday(), 0)
    }

    func testDuplicateDispatchWithPendingLdkKeepsSpend() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw NodeError.DuplicatePayment(message: "dup")
            },
            listRows: {
                [
                    QuickPayReconcileRow(
                        paymentId: "pid",
                        invoicePaymentHash: invoiceHash,
                        isOutboundBolt11: true,
                        status: .pending
                    ),
                ]
            }
        )

        guard case let .pending(paymentHash, _, _, _) = route else {
            return XCTFail("Expected pending, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentHash, invoiceHash)
        XCTAssertNotNil(store.record(matching: invoiceHash))
        XCTAssertGreaterThan(store.spentCentsToday(), 0)
    }

    func testDuplicateDispatchWithSucceededLdkReleasesFreshReserveAndFails() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw NodeError.DuplicatePayment(message: "dup")
            },
            listRows: {
                [
                    QuickPayReconcileRow(
                        paymentId: "pid",
                        invoicePaymentHash: invoiceHash,
                        isOutboundBolt11: true,
                        status: .succeeded
                    ),
                ]
            }
        )

        guard case .failure = route else {
            return XCTFail("Expected failure, got \(String(describing: route))")
        }
        XCTAssertNil(store.record(matching: invoiceHash))
        XCTAssertEqual(store.spentCentsToday(), 0)
    }

    func testAmbiguousDispatchWithSucceededLdkKeepsSpend() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw NodeError.PersistenceFailed(message: "io")
            },
            listRows: {
                [
                    QuickPayReconcileRow(
                        paymentId: "pid",
                        invoicePaymentHash: invoiceHash,
                        isOutboundBolt11: true,
                        status: .succeeded
                    ),
                ]
            }
        )

        guard case let .success(paymentId, _) = route else {
            return XCTFail("Expected success, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentId, invoiceHash)
        XCTAssertNil(store.record(matching: invoiceHash))
        XCTAssertGreaterThan(store.spentCentsToday(), 0)
    }

    func testRepayOfSettledHashFailsWithoutDoubleCounting() async throws {
        let invoiceHash = try Self.invoiceHash
        var sendCount = 0
        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { [store] _ in
                sendCount += 1
                if sendCount == 1 {
                    store?.signalCompletion(paymentId: nil, paymentHash: invoiceHash, success: true)
                    return invoiceHash
                }
                throw NodeError.DuplicatePayment(message: "dup")
            },
            listRows: {
                [
                    QuickPayReconcileRow(
                        paymentId: "pid",
                        invoicePaymentHash: invoiceHash,
                        isOutboundBolt11: true,
                        status: .succeeded
                    ),
                ]
            }
        )

        let first = await firstRoute(from: coordinator)
        guard case .success = first else {
            return XCTFail("Expected success, got \(String(describing: first))")
        }
        let spent = store.spentCentsToday()
        XCTAssertGreaterThan(spent, 0)
        coordinator.detach()

        let second = await firstRoute(from: coordinator)
        guard case .failure = second else {
            return XCTFail("Expected failure, got \(String(describing: second))")
        }
        XCTAssertEqual(sendCount, 2)
        XCTAssertEqual(store.spentCentsToday(), spent)
        XCTAssertNil(store.record(matching: invoiceHash))
    }

    func testLookupThrowOnDuplicateStillEmitsPending() async throws {
        let invoiceHash = try Self.invoiceHash
        let route = await firstRoute(
            sendBolt11: { _ in
                throw NodeError.DuplicatePayment(message: "dup")
            },
            listRows: {
                throw NSError(domain: "QuickPayLookup", code: 1)
            }
        )

        guard case let .pending(paymentHash, _, _, _) = route else {
            return XCTFail("Expected pending, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentHash, invoiceHash)
        XCTAssertNotNil(store.record(matching: invoiceHash))
        XCTAssertGreaterThan(store.spentCentsToday(), 0)
    }

    func testRescanOfPendingHashReplaysPendingToNewSession() async throws {
        let invoiceHash = try Self.invoiceHash
        var sendCount = 0
        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { _ in
                sendCount += 1
                throw NodeError.DuplicatePayment(message: "dup")
            },
            listRows: {
                [
                    QuickPayReconcileRow(
                        paymentId: "pid",
                        invoicePaymentHash: invoiceHash,
                        isOutboundBolt11: true,
                        status: .pending
                    ),
                ]
            }
        )

        let first = await firstRoute(from: coordinator)
        guard case .pending = first else {
            return XCTFail("Expected pending, got \(String(describing: first))")
        }
        coordinator.detach()
        let second = await firstRoute(from: coordinator)
        guard case let .pending(paymentHash, _, _, _) = second else {
            return XCTFail("Expected pending replay, got \(String(describing: second))")
        }
        XCTAssertEqual(paymentHash, invoiceHash)
        XCTAssertEqual(sendCount, 1)
        XCTAssertGreaterThan(store.spentCentsToday(), 0)
        XCTAssertNotNil(store.record(matching: invoiceHash))
    }

    func testZombieRescanReplaysPendingAfterDetach() async throws {
        let invoiceHash = try Self.invoiceHash
        let sendStarted = expectation(description: "send started")
        var sendCount = 0
        var didConfirm = false
        var sendCont: CheckedContinuation<String, Never>?
        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { _ in
                sendCount += 1
                return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                    sendCont = cont
                    sendStarted.fulfill()
                }
            },
            listRows: { [] }
        )

        coordinator.pay(
            app: appWithInvoice,
            wallet: WalletViewModel(),
            settings: settings,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            presentation: presentation(onRoute: { _ in }, onConfirm: { _ in })
        )
        await fulfillment(of: [sendStarted], timeout: 2)
        coordinator.detach()

        var liveSendShouldNotEmit = true
        coordinator.pay(
            app: appWithInvoice,
            wallet: WalletViewModel(),
            settings: settings,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            presentation: presentation(
                onRoute: { _ in
                    if liveSendShouldNotEmit {
                        XCTFail("Live send should not emit yet")
                    }
                },
                onConfirm: { _ in didConfirm = true }
            )
        )
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(sendCount, 1)
        XCTAssertFalse(didConfirm)
        liveSendShouldNotEmit = false
        coordinator.detach()
        sendCont?.resume(returning: invoiceHash)
        XCTAssertNotNil(store.record(matching: invoiceHash))
    }

    func testPayIgnoresReentryUntilDetach() async throws {
        let invoiceHash = try Self.invoiceHash
        let sendStarted = expectation(description: "send started")
        var sendCount = 0
        var sendCont: CheckedContinuation<String, Never>?
        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { _ in
                sendCount += 1
                return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                    sendCont = cont
                    sendStarted.fulfill()
                }
            },
            listRows: { [] }
        )

        coordinator.pay(
            app: appWithInvoice,
            wallet: WalletViewModel(),
            settings: settings,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            presentation: presentation(onRoute: { _ in }, onConfirm: { _ in })
        )
        await fulfillment(of: [sendStarted], timeout: 2)
        coordinator.pay(
            app: appWithInvoice,
            wallet: WalletViewModel(),
            settings: settings,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            presentation: presentation(onRoute: { _ in XCTFail("Re-entry should not emit") }, onConfirm: { _ in })
        )
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(sendCount, 1)
        coordinator.detach()
        sendCont?.resume(returning: invoiceHash)
    }

    func testSameSessionReattachesResultWithoutDispatchingAgain() async throws {
        let app = appWithInvoice
        let session = QuickPayPaymentCoordinator.SessionID(
            presentationID: UUID(), sendStateGeneration: app.sendStateGeneration, attempt: 0
        )
        let started = expectation(description: "Dispatch suspended")
        let delivered = expectation(description: "Reattached result delivered")
        var continuation: CheckedContinuation<Void, Never>?
        var sendCount = 0
        let coordinator = QuickPayPaymentCoordinator(store: store, sendBolt11: { _ in
            sendCount += 1
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
            throw NodeError.InvalidInvoice(message: "Fixture rejection")
        }, listRows: { [] })
        defer { coordinator.detach() }
        let wallet = WalletViewModel()
        let currency = CurrencyViewModel(currencyService: OfflineCurrencyService())
        coordinator.pay(app: app, wallet: wallet, settings: settings, currency: currency,
                        presentation: presentation(onRoute: { _ in XCTFail("Retired callback must not navigate") }, onConfirm: { _ in }),
                        sessionID: session)
        await fulfillment(of: [started], timeout: 2)
        coordinator.pay(app: app, wallet: wallet, settings: settings, currency: currency,
                        presentation: presentation(onRoute: { route in
                            guard case .failure = route else { return XCTFail("Expected rejection result") }
                            delivered.fulfill()
                        }, onConfirm: { _ in }), sessionID: session)
        try XCTUnwrap(continuation).resume()
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(sendCount, 1)
    }

    func testSameSessionReattachesAfterEarlySettlement() async throws {
        let invoiceHash = try Self.invoiceHash
        let app = appWithInvoice
        let session = QuickPayPaymentCoordinator.SessionID(
            presentationID: UUID(), sendStateGeneration: app.sendStateGeneration, attempt: 0
        )
        let started = expectation(description: "Dispatch suspended before return")
        let delivered = expectation(description: "Reattached settled result delivered")
        var continuation: CheckedContinuation<Void, Never>?
        let coordinator = QuickPayPaymentCoordinator(store: store, sendBolt11: { _ in
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
            return invoiceHash
        }, listRows: { [] })
        defer { coordinator.detach() }
        let wallet = WalletViewModel()
        let currency = CurrencyViewModel(currencyService: OfflineCurrencyService())
        coordinator.pay(app: app, wallet: wallet, settings: settings, currency: currency,
                        presentation: presentation(onRoute: { _ in XCTFail("Retired callback must not navigate") }, onConfirm: { _ in }),
                        sessionID: session)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(coordinator.complete(paymentId: nil, paymentHash: invoiceHash, success: true).wasQuickPay)
        coordinator.pay(app: app, wallet: wallet, settings: settings, currency: currency,
                        presentation: presentation(onRoute: { route in
                            guard case .success = route else { return XCTFail("Expected settled result") }
                            delivered.fulfill()
                        }, onConfirm: { _ in }), sessionID: session)
        try XCTUnwrap(continuation).resume()
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testHasOpenIsTrueForLiveOpOrRecoveredRow() async throws {
        let invoiceHash = try Self.invoiceHash
        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { _ in throw NodeError.DuplicatePayment(message: "dup") },
            listRows: { [] }
        )
        XCTAssertFalse(coordinator.hasOpen(invoiceHash))

        _ = await firstRoute(from: coordinator)
        XCTAssertTrue(coordinator.hasOpen(invoiceHash))

        XCTAssertNotNil(
            try store.reserveBound(
                paymentHash: "recovered-hash",
                amountSats: 500,
                enabled: true,
                thresholdUsd: 5,
                multiplier: 5,
                rates: rates
            )
        )
        XCTAssertTrue(coordinator.hasOpen("recovered-hash"))
        XCTAssertTrue(coordinator.complete(paymentId: nil, paymentHash: invoiceHash, success: true).wasQuickPay)
        XCTAssertFalse(coordinator.hasOpen(invoiceHash))
    }

    func testUnattributableFailedEventAgainstSubmittingRetains() throws {
        let invoiceHash = try Self.invoiceHash
        XCTAssertNotNil(
            try store.reserveBound(
                paymentHash: invoiceHash,
                amountSats: 1000,
                enabled: true,
                thresholdUsd: 5,
                multiplier: 5,
                rates: rates
            )
        )
        let coordinator = QuickPayPaymentCoordinator(store: store, sendBolt11: { _ in invoiceHash }, listRows: { [] })

        let outcome = coordinator.complete(paymentId: "stale-pid", paymentHash: invoiceHash, success: false)

        XCTAssertEqual(outcome, .none)
        XCTAssertEqual(store.spentCentsToday(), 500)
        XCTAssertNotNil(store.record(matching: invoiceHash))
    }

    func testReconcileDuringLiveDispatchedOpDoesNotStealCompletion() async throws {
        let invoiceHash = try Self.invoiceHash
        let sendStarted = expectation(description: "send started")
        var sendCont: CheckedContinuation<String, Never>?
        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { _ in
                return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                    sendCont = cont
                    sendStarted.fulfill()
                }
            },
            listRows: {
                [
                    QuickPayReconcileRow(
                        paymentId: "pid",
                        invoicePaymentHash: invoiceHash,
                        isOutboundBolt11: true,
                        status: .succeeded
                    ),
                ]
            }
        )

        coordinator.pay(
            app: appWithInvoice,
            wallet: WalletViewModel(),
            settings: settings,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            presentation: presentation(onRoute: { _ in }, onConfirm: { _ in })
        )
        await fulfillment(of: [sendStarted], timeout: 2)
        XCTAssertNotNil(store.record(matching: invoiceHash))
        let spent = store.spentCentsToday()
        XCTAssertGreaterThan(spent, 0)

        store.reconcile(
            rows: [
                QuickPayReconcileRow(
                    paymentId: "pid",
                    invoicePaymentHash: invoiceHash,
                    isOutboundBolt11: true,
                    status: .succeeded
                ),
            ],
            liveSubmittingHashes: coordinator.liveSubmittingHashes
        )
        XCTAssertNotNil(store.record(matching: invoiceHash))
        XCTAssertEqual(store.spentCentsToday(), spent)

        let outcome = coordinator.complete(paymentId: "pid", paymentHash: invoiceHash, success: true)
        XCTAssertTrue(outcome.wasQuickPay)
        XCTAssertEqual(store.spentCentsToday(), spent)
        XCTAssertNil(store.record(matching: invoiceHash))
        sendCont?.resume(returning: invoiceHash)
    }

    func testRecoveredHashThatLdkSucceededGoesToSuccess() async throws {
        let invoiceHash = try Self.invoiceHash
        var sent = false
        XCTAssertNotNil(
            try store.reserveBound(
                paymentHash: invoiceHash,
                amountSats: 1000,
                enabled: true,
                thresholdUsd: 5,
                multiplier: 5,
                rates: rates
            )
        )

        let route = await firstRoute(
            sendBolt11: { _ in
                sent = true
                return invoiceHash
            },
            listRows: {
                [
                    QuickPayReconcileRow(
                        paymentId: "pid",
                        invoicePaymentHash: invoiceHash,
                        isOutboundBolt11: true,
                        status: .succeeded
                    ),
                ]
            }
        )

        XCTAssertFalse(sent)
        guard case let .success(paymentId, _) = route else {
            return XCTFail("Expected success, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentId, invoiceHash)
        XCTAssertNil(store.record(matching: invoiceHash))
        XCTAssertEqual(store.spentCentsToday(), 500)
    }

    func testSecondPayOfInFlightHashDoesNotFallBackToConfirm() async throws {
        let invoiceHash = try Self.invoiceHash
        let sendStarted = expectation(description: "send started")
        let firstSettled = expectation(description: "first settled")
        var sendCount = 0
        var didConfirm = false
        var sendCont: CheckedContinuation<Void, Never>?

        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { [store] _ in
                sendCount += 1
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    sendCont = cont
                    sendStarted.fulfill()
                }
                store?.signalCompletion(paymentId: nil, paymentHash: invoiceHash, success: true)
                return invoiceHash
            },
            listRows: { [] }
        )

        coordinator.pay(
            app: appWithInvoice,
            wallet: WalletViewModel(),
            settings: settings,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            presentation: presentation(
                onRoute: { _ in firstSettled.fulfill() },
                onConfirm: { _ in didConfirm = true }
            )
        )
        await fulfillment(of: [sendStarted], timeout: 2)

        coordinator.pay(
            app: appWithInvoice,
            wallet: WalletViewModel(),
            settings: settings,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            presentation: presentation(
                onRoute: { _ in XCTFail("Second pay should not emit a route") },
                onConfirm: { _ in didConfirm = true }
            )
        )
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(sendCount, 1)
        XCTAssertFalse(didConfirm)

        sendCont?.resume()
        await fulfillment(of: [firstSettled], timeout: 2)
        XCTAssertEqual(sendCount, 1)
        XCTAssertFalse(didConfirm)
    }

    func testDisabledFreshPaymentFallsBackToConfirmWithoutSending() async throws {
        let invoiceHash = try Self.invoiceHash
        settings.enableQuickpay = false
        var sent = false
        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { _ in
                sent = true
                return invoiceHash
            },
            listRows: { [] }
        )

        let outcome = await firstOutcome(from: coordinator)

        XCTAssertFalse(sent)
        guard case .confirm(.confirm) = outcome else {
            return XCTFail("Expected confirm fallback, got \(String(describing: outcome))")
        }
        XCTAssertFalse(coordinator.hasOpen(invoiceHash))
        XCTAssertEqual(store.spentCentsToday(), 0)
    }

    func testDisabledRepayAfterFailedRecordIsReconciledAwayFallsBackToConfirm() async throws {
        let invoiceHash = try Self.invoiceHash
        try reserveSubmittedRecord(invoiceHash)
        settings.enableQuickpay = false
        var sent = false
        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { _ in
                sent = true
                return invoiceHash
            },
            listRows: {
                [QuickPayReconcileRow(paymentId: "pid", invoicePaymentHash: invoiceHash, isOutboundBolt11: true, status: .failed)]
            }
        )
        // Routing still opens QuickPay for the saved hash while it is disabled.
        XCTAssertTrue(coordinator.hasOpen(invoiceHash))

        coordinator.reconcileAgainstLdk()
        for _ in 0 ..< 200 where store.record(matching: invoiceHash) != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(store.record(matching: invoiceHash))

        let outcome = await firstOutcome(from: coordinator)

        XCTAssertFalse(sent)
        guard case .confirm(.confirm) = outcome else {
            return XCTFail("Expected confirm fallback, got \(String(describing: outcome))")
        }
        XCTAssertNil(store.record(matching: invoiceHash))
        XCTAssertEqual(store.spentCentsToday(), 0)
    }

    func testDisabledSubmittedPendingRecordStaysPendingWithoutSending() async throws {
        let invoiceHash = try Self.invoiceHash
        try reserveSubmittedRecord(invoiceHash)
        settings.enableQuickpay = false
        var sent = false

        let route = await firstRoute(
            sendBolt11: { _ in
                sent = true
                return invoiceHash
            },
            listRows: {
                [QuickPayReconcileRow(paymentId: "pid", invoicePaymentHash: invoiceHash, isOutboundBolt11: true, status: .pending)]
            }
        )

        XCTAssertFalse(sent)
        guard case let .pending(paymentHash, _, _, _) = route else {
            return XCTFail("Expected pending, got \(String(describing: route))")
        }
        XCTAssertEqual(paymentHash, invoiceHash)
        XCTAssertNotNil(store.record(matching: invoiceHash))
        XCTAssertEqual(store.spentCentsToday(), 500)
    }

    func testDisabledSubmittedRecordThatLdkSucceededSettlesWithoutSending() async throws {
        let invoiceHash = try Self.invoiceHash
        try reserveSubmittedRecord(invoiceHash)
        settings.enableQuickpay = false
        var sent = false

        let route = await firstRoute(
            sendBolt11: { _ in
                sent = true
                return invoiceHash
            },
            listRows: {
                [QuickPayReconcileRow(paymentId: "pid", invoicePaymentHash: invoiceHash, isOutboundBolt11: true, status: .succeeded)]
            }
        )

        XCTAssertFalse(sent)
        guard case .success = route else {
            return XCTFail("Expected success, got \(String(describing: route))")
        }
        XCTAssertNil(store.record(matching: invoiceHash))
        XCTAssertEqual(store.spentCentsToday(), 500)
    }

    func testDisabledLnurlFallsBackToConfirmBeforeFetchingInvoice() async throws {
        settings.enableQuickpay = false
        var sent = false
        let app = AppViewModel()
        let wallet = WalletViewModel()
        // The `.invalid` callback never resolves, so a fetch would surface as a failure route instead of the fallback.
        app.lnurlPayData = LnurlPayData(
            uri: "https://lnurl.invalid/pay", callback: "https://lnurl.invalid/callback",
            minSendable: 1_000_000, maxSendable: 1_000_000,
            metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
        )
        let coordinator = QuickPayPaymentCoordinator(
            store: store,
            sendBolt11: { bolt11 in
                sent = true
                return bolt11
            },
            listRows: { [] }
        )

        let outcome = await firstOutcome(from: coordinator, app: app, wallet: wallet)

        XCTAssertFalse(sent)
        guard case .confirm(.lnurlPayConfirm) = outcome else {
            return XCTFail("Expected LNURL confirm fallback, got \(String(describing: outcome))")
        }
        XCTAssertNil(wallet.sendAmountSats)
        XCTAssertEqual(store.spentCentsToday(), 0)
    }

    private func reserveSubmittedRecord(_ invoiceHash: String) throws {
        XCTAssertNotNil(
            try store.reserveBound(
                paymentHash: invoiceHash,
                amountSats: 1000,
                enabled: true,
                thresholdUsd: 5,
                multiplier: 5,
                rates: rates
            )
        )
        store.markSubmitted(invoicePaymentHash: invoiceHash, paymentId: "pid")
    }

    private func firstRoute(
        sendBolt11: @escaping (String) async throws -> String,
        listRows: @escaping () async throws -> [QuickPayReconcileRow]? = { [] }
    ) async -> SendRoute? {
        let coordinator = QuickPayPaymentCoordinator(store: store, sendBolt11: sendBolt11, listRows: listRows)
        return await firstRoute(from: coordinator)
    }

    private func firstRoute(from coordinator: QuickPayPaymentCoordinator, wallet: WalletViewModel? = nil) async -> SendRoute? {
        guard case let .route(route) = await firstOutcome(from: coordinator, wallet: wallet) else { return nil }
        return route
    }

    private enum PayOutcome {
        case route(SendRoute)
        case confirm(SendRoute)
    }

    private func firstOutcome(
        from coordinator: QuickPayPaymentCoordinator,
        app: AppViewModel? = nil,
        wallet: WalletViewModel? = nil
    ) async -> PayOutcome? {
        var outcome: PayOutcome?
        let exp = expectation(description: "outcome")
        coordinator.pay(
            app: app ?? appWithInvoice,
            wallet: wallet ?? WalletViewModel(),
            settings: settings,
            currency: CurrencyViewModel(currencyService: OfflineCurrencyService()),
            presentation: presentation(
                onRoute: {
                    outcome = .route($0)
                    exp.fulfill()
                },
                onConfirm: {
                    outcome = .confirm($0)
                    exp.fulfill()
                }
            )
        )
        await fulfillment(of: [exp], timeout: 2)
        return outcome
    }

    private func presentation(
        onRoute: @escaping (SendRoute) -> Void,
        onConfirm: @escaping (SendRoute) -> Void
    ) -> QuickPayPaymentCoordinator.Presentation {
        QuickPayPaymentCoordinator.Presentation(
            appendRoute: onRoute,
            replaceQuickPay: onConfirm,
            addPendingPaymentHash: { _ in },
            routingCacheResetAttempted: false
        )
    }

    private var appWithInvoice: AppViewModel {
        let app = AppViewModel()
        app.scannedLightningInvoice = LightningInvoice(
            bolt11: Self.regtestBolt11,
            paymentHash: Data(),
            amountSatoshis: 1000,
            timestampSeconds: 0,
            expirySeconds: 0,
            isExpired: false,
            description: nil,
            networkType: .regtest,
            payeeNodeId: nil
        )
        return app
    }

    private var usdRate: FxRate {
        FxRate(
            symbol: "BTCUSD",
            lastPrice: "100000",
            base: "BTC",
            baseName: "Bitcoin",
            quote: "USD",
            quoteName: "US Dollar",
            currencySymbol: "$",
            currencyFlag: "🇺🇸",
            lastUpdatedAt: 0
        )
    }

    private static var invoiceHash: String {
        get throws {
            try String(Bolt11Invoice.fromStr(invoiceStr: regtestBolt11).paymentHash())
        }
    }

    private final class CoordinatorHolder {
        var coordinator: QuickPayPaymentCoordinator?
    }

    private static let regtestBolt11 =
        "lnbcrt200n1p5hn4c8dqqnp4qwrgh4a03djj2sl34465uwnxhva0gtpjm4u8kvzgc5jergrkm9syypp55lwcgfpkdwuknmekjgted72n0ddl5qtaha7knk7c9n7yrjr4auassp5jgqw0a9w33e2ta4j7gyjrvsvu0lv844w895305nd8spnknq3f2hq9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcsqqqqlgqqqqqqgq2qd2gk64eg2kfxtdaryrlh98hvu97jdaxz2ma7aeyuy2uy9vkn9x5qft47p9taju297xnrehva20xcfml7wacuv737xv3xjjzyrtplcxqpfpu9dt"
}
