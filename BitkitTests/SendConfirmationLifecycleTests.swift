@testable import Bitkit
import BitkitCore
import Combine
import LDKNode
import SwiftUI
import XCTest

@MainActor
final class SendConfirmationLifecycleTests: XCTestCase {
    func testSuspendedPreparationCannotChangeClosedOrReplacementSend() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        for operation in [ControlledSendWallet.Operation.fee, .manualUtxos, .selection] {
            for (replacement, fails) in [(false, false), (true, true)] {
                let wallet = ControlledSendWallet(operation: operation, fails: fails)
                let app = AppViewModel()
                let sheets = SheetViewModel()
                sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
                app.scannedOnchainInvoice = invoice
                app.selectedWalletToPayFrom = .lightning
                wallet.sendAmountSats = 6007
                wallet.selectedFeeRateSatsPerVByte = operation == .fee ? nil : 2
                SettingsViewModel.shared.coinSelectionMethod = operation == .manualUtxos ? .manual : .autopilot
                var path: [SendRoute] = []
                var shownToasts: [Bitkit.Toast] = []
                let subscription = ToastWindowManager.shared.$currentToast.compactMap { $0 }.sink { shownToasts.append($0) }
                let window = host(app: app, wallet: wallet, sheets: sheets, path: Binding(get: { path }, set: { path = $0 }))
                defer {
                    close(window)
                    subscription.cancel()
                    ToastWindowManager.shared.hideToast()
                }
                try await Task.sleep(for: .milliseconds(100))
                app.selectedWalletToPayFrom = .onchain
                await fulfillment(of: [wallet.started], timeout: 3)

                app.resetSendState()
                wallet.resetSendState(speed: .normal)
                if replacement {
                    sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
                    app.scannedOnchainInvoice = invoice
                    wallet.sendAmountSats = 6007
                }
                wallet.resume()
                await fulfillment(of: [wallet.finished], timeout: 3)
                try await Task.sleep(for: .milliseconds(150))

                XCTAssertNil(wallet.selectedFeeRateSatsPerVByte)
                XCTAssertNil(wallet.selectedUtxos)
                XCTAssertEqual(app.selectedWalletToPayFrom, .onchain)
                XCTAssertTrue(path.isEmpty)
                XCTAssertTrue(shownToasts.isEmpty)
            }
        }
    }

    func testLeavingConfirmationCancelsSuspendedPreparation() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let wallet = ControlledSendWallet(operation: .fee)
        let app = AppViewModel()
        let sheets = SheetViewModel()
        sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
        app.scannedOnchainInvoice = invoice
        app.selectedWalletToPayFrom = .lightning
        wallet.sendAmountSats = 6007
        let window = host(app: app, wallet: wallet, sheets: sheets, path: .constant([]))
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(100))
        app.selectedWalletToPayFrom = .onchain
        await fulfillment(of: [wallet.started], timeout: 3)
        window.rootViewController = UIHostingController(rootView: Color.black)
        try await Task.sleep(for: .milliseconds(100))
        wallet.resume()
        await fulfillment(of: [wallet.finished], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(wallet.wasCancelled)
        XCTAssertNil(wallet.selectedFeeRateSatsPerVByte)
        XCTAssertNil(wallet.selectedUtxos)
    }

    func testActiveSwitchPreparesUtxosAndStillReportsGenuineErrors() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        for operation in [ControlledSendWallet.Operation.fee, .manualUtxos, .selection] {
            for fails in [false, true] {
                let wallet = ControlledSendWallet(operation: operation, fails: fails)
                let app = AppViewModel()
                let sheets = SheetViewModel()
                sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
                app.scannedOnchainInvoice = invoice
                app.selectedWalletToPayFrom = .lightning
                wallet.sendAmountSats = 6007
                wallet.selectedFeeRateSatsPerVByte = operation == .fee ? nil : 2
                SettingsViewModel.shared.coinSelectionMethod = operation == .manualUtxos ? .manual : .autopilot
                var path: [SendRoute] = operation == .selection ? [.feeRate] : []
                ToastWindowManager.shared.hideToast()
                var shownToasts: [Bitkit.Toast] = []
                let subscription = ToastWindowManager.shared.$currentToast.compactMap { $0 }.sink { shownToasts.append($0) }
                let window = host(app: app, wallet: wallet, sheets: sheets, path: Binding(get: { path }, set: { path = $0 }))
                defer {
                    close(window)
                    subscription.cancel()
                    ToastWindowManager.shared.hideToast()
                }
                try await Task.sleep(for: .milliseconds(100))
                app.selectedWalletToPayFrom = .onchain
                path = []
                await fulfillment(of: [wallet.started], timeout: 3)
                wallet.resume()
                await fulfillment(of: [wallet.finished], timeout: 3)
                try await Task.sleep(for: .milliseconds(100))

                XCTAssertEqual(app.selectedWalletToPayFrom, fails ? .lightning : .onchain)
                XCTAssertEqual(shownToasts.isEmpty, !fails)
                XCTAssertEqual(path, !fails && operation == .manualUtxos ? [.utxoSelection] : [])
                if !fails, operation == .selection {
                    XCTAssertNotNil(wallet.selectedUtxos)
                }
            }
        }
    }

    func testRetiringConfirmationDoesNotPrepareAReplacementPresentation() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let app = AppViewModel()
        let wallet = WalletViewModel()
        let sheets = SheetViewModel()
        sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
        FeeEstimatesManager().devOverrideFeeEstimates = true
        app.scannedOnchainInvoice = invoice
        app.selectedWalletToPayFrom = .lightning
        wallet.sendAmountSats = 6007
        ToastWindowManager.shared.hideToast()
        var shownToasts: [Bitkit.Toast] = []
        let subscription = ToastWindowManager.shared.$currentToast.compactMap { $0 }.sink { shownToasts.append($0) }
        let window = host(app: app, wallet: wallet, sheets: sheets, path: .constant([]))
        defer {
            close(window)
            subscription.cancel()
            ToastWindowManager.shared.hideToast()
        }
        try await Task.sleep(for: .milliseconds(100))

        sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
        app.selectedWalletToPayFrom = .onchain
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(wallet.selectedFeeRateSatsPerVByte)
        XCTAssertNil(wallet.selectedUtxos)
        XCTAssertEqual(app.selectedWalletToPayFrom, .onchain)
        XCTAssertEqual(wallet.sendAmountSats, 6007)
        XCTAssertTrue(shownToasts.isEmpty)
    }

    func testCustomFeeWalletSwitchSurvivesFeeScreenNavigation() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        FeeEstimatesManager().devOverrideFeeEstimates = true
        for operation in [ControlledSendWallet.Operation.manualUtxos, .selection] {
            let wallet = ControlledSendWallet(operation: operation)
            let app = AppViewModel()
            let sheets = SheetViewModel()
            sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
            app.scannedOnchainInvoice = invoice
            app.selectedWalletToPayFrom = .lightning
            wallet.sendAmountSats = 6007
            wallet.selectedFeeRateSatsPerVByte = 2
            SettingsViewModel.shared.coinSelectionMethod = operation == .manualUtxos ? .manual : .autopilot
            let navigation = SendConfirmationTestNavigation()
            let window = host(app: app, wallet: wallet, sheets: sheets,
                              path: Binding(get: { navigation.path }, set: { navigation.path = $0 }), navigation: navigation)
            defer { close(window) }
            try await navigation.waitForAppearance(.confirm)

            navigation.path.append(.feeRate)
            try await navigation.waitForAppearance(.feeRate)
            XCTAssertEqual(navigation.confirmationDisappearances, 1)
            navigation.path.append(.feeCustom)
            try await navigation.waitForAppearance(.feeCustom)
            wallet.selectedSpeed = .custom(satsPerVByte: 3)
            wallet.selectedFeeRateSatsPerVByte = 3
            app.selectedWalletToPayFrom = .onchain
            navigation.path.removeLast()
            try await navigation.waitForAppearance(.feeRate)
            XCTAssertEqual(wallet.preparationCount, 0)
            XCTAssertEqual(navigation.path, [.confirm, .feeRate])

            navigation.path.removeLast()
            try await navigation.waitForAppearance(.confirm)
            await fulfillment(of: [wallet.started], timeout: 3)
            guard wallet.preparationCount > 0 else { continue }
            wallet.resume()
            await fulfillment(of: [wallet.finished], timeout: 3)
            try await Task.sleep(for: .milliseconds(100))

            XCTAssertEqual(wallet.preparationCount, 1)
            XCTAssertEqual(app.selectedWalletToPayFrom, .onchain)
            XCTAssertEqual(navigation.path, operation == .manualUtxos ? [.confirm, .utxoSelection] : [.confirm])
            if operation == .selection { XCTAssertNotNil(wallet.selectedUtxos) }
        }
    }

    func testCustomFeePendingWalletSwitchDoesNotSurviveSendTeardown() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        for teardown in ["reset", "dismiss", "replace", "leaveFeeFlow"] {
            let wallet = ControlledSendWallet(operation: .manualUtxos)
            let app = AppViewModel()
            let sheets = SheetViewModel()
            sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
            app.scannedOnchainInvoice = invoice
            app.selectedWalletToPayFrom = .lightning
            wallet.sendAmountSats = 6007
            wallet.selectedFeeRateSatsPerVByte = 2
            SettingsViewModel.shared.coinSelectionMethod = .manual
            let navigation = SendConfirmationTestNavigation()
            let window = host(app: app, wallet: wallet, sheets: sheets,
                              path: Binding(get: { navigation.path }, set: { navigation.path = $0 }))
            defer { close(window) }
            try await Task.sleep(for: .milliseconds(100))
            navigation.path = [.confirm, .feeRate, .feeCustom]
            await Task.yield()
            try await Task.sleep(for: .milliseconds(100))
            app.selectedWalletToPayFrom = .onchain
            navigation.path.removeLast()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(100))

            switch teardown {
            case "reset":
                app.resetSendState()
                wallet.resetSendState(speed: .normal)
            case "dismiss": sheets.activeSheetConfiguration = nil
            case "replace": sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
            default: navigation.path = [.amount]
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(100))
            navigation.path = [.confirm]
            await Task.yield()
            try await Task.sleep(for: .milliseconds(150))

            XCTAssertEqual(wallet.preparationCount, 0, teardown)
            XCTAssertNil(wallet.selectedUtxos, teardown)
            XCTAssertEqual(navigation.path, [.confirm], teardown)
        }
    }

    func testSuccessResetDoesNotPrepareOnchainSendWhileConfirmationIsMounted() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let app = AppViewModel()
        let wallet = WalletViewModel()
        let sheets = SheetViewModel()
        sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
        FeeEstimatesManager().devOverrideFeeEstimates = true
        app.selectedWalletToPayFrom = .lightning
        wallet.sendAmountSats = 6007
        var path: [SendRoute] = []
        ToastWindowManager.shared.hideToast()
        var shownToasts: [Bitkit.Toast] = []
        let subscription = ToastWindowManager.shared.$currentToast.compactMap { $0 }.sink { shownToasts.append($0) }
        let window = host(app: app, wallet: wallet, sheets: sheets, path: Binding(get: { path }, set: { path = $0 }))
        defer {
            close(window)
            subscription.cancel()
            ToastWindowManager.shared.hideToast()
        }
        try await Task.sleep(for: .milliseconds(150))

        path = [.success(paymentId: "synthetic-success")]
        sheets.activeSheetConfiguration = nil
        app.resetSendState()
        wallet.resetSendState(speed: .normal)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(wallet.sendAmountSats)
        XCTAssertNil(wallet.selectedFeeRateSatsPerVByte)
        XCTAssertNil(wallet.selectedUtxos)
        XCTAssertEqual(app.selectedWalletToPayFrom, .onchain)
        XCTAssertEqual(path, [.success(paymentId: "synthetic-success")])
        XCTAssertTrue(shownToasts.isEmpty)
    }

    private func host(
        app: AppViewModel,
        wallet: WalletViewModel,
        sheets: SheetViewModel,
        path: Binding<[SendRoute]>,
        navigation: SendConfirmationTestNavigation? = nil
    ) -> UIWindow {
        let hwSend = HwSendCoordinator()
        let confirmation = SendConfirmationView(
            navigationPath: path,
            isSubmittingPayment: .constant(false),
            hwSend: hwSend,
            requestPinCheck: {
                XCTFail("Preparing confirmation must not authorize a payment")
                return false
            },
            prepareIncomingPaymentRequest: {
                XCTFail("Preparing confirmation must not submit a payment request")
            },
            routingCacheResetAttempted: false
        )
        let view = Group {
            if let navigation {
                @Bindable var navigation = navigation
                NavigationStack(path: $navigation.path) {
                    Color.clear
                        .navigationDestination(for: SendRoute.self) { route in
                            Group {
                                switch route {
                                case .confirm: confirmation
                                case .feeRate: SendFeeRate(navigationPath: $navigation.path, hwSend: hwSend)
                                case .feeCustom: SendFeeCustom(navigationPath: $navigation.path, hwSend: hwSend)
                                default: Color.clear
                                }
                            }
                            .onAppear { navigation.visibleRoutes.insert(route) }
                            .onDisappear {
                                navigation.visibleRoutes.remove(route)
                                if route == .confirm { navigation.confirmationDisappearances += 1 }
                            }
                        }
                }
            } else {
                confirmation
            }
        }
        .environment(PaykitPaymentRequestManager())
        .environment(HwWalletManager())
        .environmentObject(app)
        .environmentObject(wallet)
        .environmentObject(sheets)
        .environmentObject(ActivityListViewModel())
        .environmentObject(ContactsManager())
        .environmentObject(CurrencyViewModel(currencyService: OfflineCurrencyService()))
        .environmentObject(FeeEstimatesManager())
        .environmentObject(SettingsViewModel.shared)
        .environmentObject(TagManager())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        if navigation != nil {
            // Navigation transitions need a scene-backed window.
            window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        }
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private var invoice: OnChainInvoice {
        OnChainInvoice(address: "bcrt1qexample", amountSatoshis: 6007, label: nil, message: nil, params: nil)
    }
}

@Observable
@MainActor
private final class SendConfirmationTestNavigation {
    var path: [SendRoute] = [.confirm]
    var visibleRoutes: Set<SendRoute> = []
    var confirmationDisappearances = 0

    func waitForAppearance(_ route: SendRoute, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while visibleRoutes != [route], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(visibleRoutes, [route], file: file, line: line)
    }
}

@MainActor
private final class ControlledSendWallet: WalletViewModel {
    enum Operation { case fee, manualUtxos, selection }

    let started = XCTestExpectation(description: "Send preparation suspended")
    let finished = XCTestExpectation(description: "Send preparation resumed")
    private let operation: Operation
    private let fails: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false
    private(set) var preparationCount = 0

    init(operation: Operation, fails: Bool = false) {
        self.operation = operation
        self.fails = fails
        super.init(
            transferService: TransferService(lightningService: .shared, blocktankService: Bitkit.CoreService.shared.blocktank),
            sheetViewModel: SheetViewModel(),
            feeEstimatesManager: FeeEstimatesManager()
        )
    }

    override func setFeeRate(speed: TransactionSpeed, isCurrentSend: () -> Bool = { true }) async throws {
        if operation == .fee { try await suspend() }
        guard !Task.isCancelled, isCurrentSend() else { throw CancellationError() }
        selectedFeeRateSatsPerVByte = 2
    }

    override func loadAvailableUtxos(isCurrentSend: () -> Bool = { true }) async throws {
        try await suspend()
        guard !Task.isCancelled, isCurrentSend() else { throw CancellationError() }
        availableUtxos = []
    }

    override func setUtxoSelection(coinSelectionAlgorythm: CoinSelectionAlgorithm, isCurrentSend: () -> Bool = { true }) async throws {
        if operation == .selection { try await suspend() }
        guard !Task.isCancelled, isCurrentSend() else { throw CancellationError() }
        selectedUtxos = []
    }

    override func calculateTotalFee(address: String, amountSats: UInt64, satsPerVByte: UInt32,
                                    utxosToSpend: [SpendableUtxo]? = nil) async throws -> UInt64
    {
        10
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func suspend() async throws {
        preparationCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        wasCancelled = Task.isCancelled
        finished.fulfill()
        if fails { throw AppError(message: "UTXO selection unavailable", debugMessage: nil) }
    }
}
