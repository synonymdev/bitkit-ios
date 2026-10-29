@testable import Bitkit
import BitkitCore
import Combine
import LDKNode
import Paykit
import SwiftUI
import XCTest

@MainActor
final class SendConfirmationLifecycleTests: XCTestCase {
    func testFixedLightningReviewUsesInvoiceAmountAfterEditingAnotherFundingSource() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let app = AppViewModel()
        let wallet = WalletViewModel()
        let sheets = SheetViewModel()
        sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
        app.scannedLightningInvoice = LightningInvoice(
            bolt11: "test-invoice", paymentHash: Data(), amountSatoshis: 10000,
            timestampSeconds: 0, expirySeconds: 0, isExpired: false,
            description: nil, networkType: .regtest, payeeNodeId: nil
        )
        app.selectedWalletToPayFrom = .lightning
        wallet.sendAmountSats = 1000
        let window = host(app: app, wallet: wallet, sheets: sheets, path: .constant([]))
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(wallet.sendAmountSats, 10000)
    }

    func testQuotedWalletSwitchRebindsAmountOnConfirmation() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let request = try onchainRequest(acceptsLightning: true, rates: [
            ConversionRate(asset: "btc", value: "0.000002188"),
            ConversionRate(asset: "btc-lightning", value: "0.00002"),
        ])
        let wallet = ControlledSendWallet(operation: .selection)
        let app = AppViewModel()
        let sheets = SheetViewModel()
        sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
        app.scannedOnchainInvoice = invoice
        app.scannedLightningInvoice = LightningInvoice(
            bolt11: "test-invoice", paymentHash: Data(), amountSatoshis: 0,
            timestampSeconds: 0, expirySeconds: 0, isExpired: false,
            description: nil, networkType: .regtest, payeeNodeId: nil
        )
        app.selectedWalletToPayFrom = .lightning
        app.contactPaymentContext = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
        app.paykitPaymentTerms = try request.payment(using: app.paykitPaymentMethod)
        app.paykitReviewedAmount = app.paykitPaymentTerms?.amount
        wallet.sendAmountSats = app.paykitReviewedAmount?.atomic
        wallet.selectedFeeRateSatsPerVByte = 2
        SettingsViewModel.shared.coinSelectionMethod = .autopilot
        var path: [SendRoute] = []
        let window = host(app: app, wallet: wallet, sheets: sheets, path: Binding(get: { path }, set: { path = $0 }))
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(wallet.sendAmountSats, 5000)

        app.selectedWalletToPayFrom = .onchain
        await fulfillment(of: [wallet.started], timeout: 3)
        XCTAssertTrue(path.isEmpty)
        XCTAssertEqual(wallet.sendAmountSats, 547)
        XCTAssertEqual(app.paykitPaymentTerms, try request.payment(using: app.paykitPaymentMethod))
        XCTAssertEqual(app.paykitReviewedAmount, app.paykitPaymentTerms?.amount)
        wallet.resume()
        await fulfillment(of: [wallet.finished], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(path.isEmpty)

        app.selectedWalletToPayFrom = .lightning
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(path.isEmpty)
        XCTAssertEqual(wallet.sendAmountSats, 5000)
        XCTAssertEqual(app.paykitPaymentTerms, try request.payment(using: app.paykitPaymentMethod))
        XCTAssertEqual(app.paykitReviewedAmount, app.paykitPaymentTerms?.amount)
        XCTAssertEqual(wallet.routingAmounts.last, 5000)
    }

    func testQuotedWalletSwitchRequiresReviewForUnavailableExpiredOrBelowMinimumTerms() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        for failure in ["unreviewed", "unavailable", "expired", "lightningMinimum", "onchainMinimum"] {
            let request = try onchainRequest(acceptsLightning: true)
            let wallet = ControlledSendWallet(operation: .fee)
            let app = AppViewModel()
            let sheets = SheetViewModel()
            sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
            app.scannedOnchainInvoice = invoice
            app.lnurlPayData = LnurlPayData(
                uri: "https://example.com/pay", callback: "https://example.com/callback",
                minSendable: 1_000_000, maxSendable: 100_000_000,
                metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
            )
            app.selectedWalletToPayFrom = failure == "onchainMinimum" ? .lightning : .onchain
            app.contactPaymentContext = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
            app.paykitPaymentTerms = try request.payment(using: app.paykitPaymentMethod)
            app.paykitReviewedAmount = app.paykitPaymentTerms?.amount
            wallet.sendAmountSats = app.paykitReviewedAmount?.atomic
            if failure == "unreviewed" {
                app.paykitPaymentTerms = nil
                app.paykitReviewedAmount = nil
            }
            let navigation = SendConfirmationTestNavigation()
            navigation.path = []
            let window = host(
                app: app, wallet: wallet, sheets: sheets,
                path: Binding(get: { navigation.path }, set: { navigation.path = $0 }), navigation: navigation, confirmationIsRoot: true
            )
            defer { close(window) }
            try await Task.sleep(for: .milliseconds(100))
            if failure != "unreviewed" {
                XCTAssertTrue(navigation.path.isEmpty)

                var rates = [ConversionRate(asset: "btc-regtest", value: failure == "onchainMinimum" ? "0.000002184" : "0.00001")]
                if failure != "unavailable" {
                    rates.append(ConversionRate(asset: "btc-lightning", value: failure == "lightningMinimum" ? "0.000001" : "0.00002"))
                }
                let changed = try onchainRequest(
                    acceptsLightning: true, rates: rates,
                    deadline: failure == "expired" ? .at(timestamp: "2000-01-01T00:00:00Z") : nil
                )
                app.contactPaymentContext = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: changed)
                app.selectedWalletToPayFrom = failure == "onchainMinimum" ? .onchain : .lightning
                try await Task.sleep(for: .milliseconds(100))
            }

            XCTAssertEqual(navigation.path, [.amount], failure)
            XCTAssertNil(app.paykitPaymentTerms, failure)
            XCTAssertNil(app.paykitReviewedAmount, failure)
            if failure == "onchainMinimum" {
                XCTAssertEqual(wallet.preparationCount, 0, failure)
            } else {
                XCTAssertTrue(wallet.routingAmounts.isEmpty, failure)
            }
            navigation.path.removeLast()
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(navigation.path.isEmpty, "Back must not reopen Amount: " + failure)
            XCTAssertNil(sheets.activeSheetConfiguration, "Back must close the fallback review: " + failure)
        }
    }

    func testDirectQuotedOnchainReviewPreparesSavedCoinSelection() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let request = try onchainRequest()
        for (manual, fails, retryRate) in [
            (false, false, false), (true, false, false), (false, true, false), (true, true, false), (false, false, true),
        ] {
            let wallet = ControlledSendWallet(operation: manual ? .manualUtxos : .selection, fails: fails)
            let app = AppViewModel()
            let sheets = SheetViewModel()
            sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
            app.scannedOnchainInvoice = invoice
            app.selectedWalletToPayFrom = .onchain
            app.contactPaymentContext = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
            app.paykitPaymentTerms = try request.payment(using: app.paykitPaymentMethod)
            app.paykitReviewedAmount = app.paykitPaymentTerms?.amount
            wallet.sendAmountSats = app.paykitPaymentTerms?.amount.atomic
            wallet.selectedFeeRateSatsPerVByte = retryRate ? nil : 2
            if retryRate {
                try? await wallet.loadFeeRateWithRetry(speed: .normal, retryDelay: .milliseconds(1)) { _ in
                    throw Bitkit.AppError(message: "Fee unavailable", debugMessage: nil)
                }
            }
            SettingsViewModel.shared.coinSelectionMethod = manual ? .manual : .autopilot
            SettingsViewModel.shared.coinSelectionAlgorithm = .largestFirst
            let navigation = SendConfirmationTestNavigation()
            let window = host(
                app: app, wallet: wallet, sheets: sheets,
                path: Binding(get: { navigation.path }, set: { navigation.path = $0 }), navigation: navigation
            )
            defer {
                close(window)
                ToastWindowManager.shared.hideToast()
            }
            if retryRate {
                try await navigation.waitForAppearance(.confirm)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(wallet.preparationCount, 0)
                XCTAssertEqual(navigation.path, [.confirm])
                try await wallet.loadFeeRateWithRetry(speed: .normal) { _ in
                    wallet.selectedFeeRateSatsPerVByte = 2
                }
            }
            await fulfillment(of: [wallet.started], timeout: 3)
            wallet.resume()
            await fulfillment(of: [wallet.finished], timeout: 3)
            try await Task.sleep(for: .milliseconds(100))

            XCTAssertEqual(wallet.sendAmountSats, 2500)
            XCTAssertEqual(app.selectedWalletToPayFrom, .onchain)
            XCTAssertEqual(navigation.path, fails ? [.amount] : manual ? [.confirm, .utxoSelection] : [.confirm])
            if !manual {
                XCTAssertEqual(wallet.selectedAlgorithm, .largestFirst)
                XCTAssertEqual(wallet.selectedUtxos != nil, !fails)
                XCTAssertEqual(wallet.feeUtxos != nil, !fails)
            }
        }
    }

    func testCoinPreparationFailureBackClosesUnreviewedConfirmationRoot() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        for (manual, quoted, reviewAgain) in [(false, true, false), (true, true, false), (false, false, false), (false, true, true)] {
            let request = try onchainRequest(isQuoted: quoted)
            let wallet = ControlledSendWallet(operation: manual ? .manualUtxos : .selection, fails: true)
            let app = AppViewModel()
            let sheets = SheetViewModel()
            sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
            app.scannedOnchainInvoice = invoice
            app.selectedWalletToPayFrom = .onchain
            app.contactPaymentContext = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
            app.paykitPaymentTerms = try request.payment(using: app.paykitPaymentMethod)
            app.paykitReviewedAmount = app.paykitPaymentTerms?.amount
            wallet.sendAmountSats = app.paykitPaymentTerms?.amount.atomic
            wallet.selectedFeeRateSatsPerVByte = 2
            SettingsViewModel.shared.coinSelectionMethod = manual ? .manual : .autopilot
            let navigation = SendConfirmationTestNavigation()
            navigation.path = []
            let window = host(
                app: app, wallet: wallet, sheets: sheets,
                path: Binding(get: { navigation.path }, set: { navigation.path = $0 }), navigation: navigation, confirmationIsRoot: true
            )
            defer {
                close(window)
                ToastWindowManager.shared.hideToast()
            }
            await fulfillment(of: [wallet.started], timeout: 3)
            wallet.resume()
            await fulfillment(of: [wallet.finished], timeout: 3)
            try await navigation.waitForAppearance(.amount)
            XCTAssertEqual(navigation.path, [.amount])
            XCTAssertNotNil(sheets.activeSheetConfiguration)
            XCTAssertNil(wallet.selectedUtxos)
            XCTAssertNil(app.paykitPaymentTerms)
            XCTAssertNil(app.paykitReviewedAmount)
            let preparationsBeforeBack = wallet.preparationCount

            guard navigation.path.last == .amount else { continue }
            if reviewAgain {
                app.paykitPaymentTerms = try request.payment(using: app.paykitPaymentMethod)
                app.paykitReviewedAmount = app.paykitPaymentTerms?.amount
                wallet.selectedUtxos = []
            }
            navigation.path.removeLast()
            try await Task.sleep(for: .milliseconds(500))

            XCTAssertTrue(navigation.path.isEmpty, "Back must not reopen Amount after failed coin preparation")
            XCTAssertEqual(sheets.activeSheetConfiguration != nil, reviewAgain,
                           "Only an explicitly reviewed fallback may return to confirmation")
            XCTAssertEqual(wallet.preparationCount, preparationsBeforeBack, "Back must not retry coin preparation")
            XCTAssertEqual(wallet.successfulCoinPreparations, 0)
        }
    }

    func testQuotedRequestManualPickerBackReturnsToConfirmation() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let request = try onchainRequest()
        let wallet = ControlledSendWallet(operation: .manualUtxos)
        let app = AppViewModel()
        let sheets = SheetViewModel()
        sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
        app.scannedOnchainInvoice = invoice
        app.selectedWalletToPayFrom = .onchain
        app.contactPaymentContext = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
        app.paykitPaymentTerms = try request.payment(using: app.paykitPaymentMethod)
        app.paykitReviewedAmount = app.paykitPaymentTerms?.amount
        wallet.sendAmountSats = app.paykitPaymentTerms?.amount.atomic
        wallet.selectedFeeRateSatsPerVByte = 2
        SettingsViewModel.shared.coinSelectionMethod = .manual
        let navigation = SendConfirmationTestNavigation()
        navigation.path = []
        let window = host(
            app: app, wallet: wallet, sheets: sheets,
            path: Binding(get: { navigation.path }, set: { navigation.path = $0 }), navigation: navigation, confirmationIsRoot: true
        )
        defer {
            close(window)
            ToastWindowManager.shared.hideToast()
        }
        await fulfillment(of: [wallet.started], timeout: 3)
        wallet.resume()
        await fulfillment(of: [wallet.finished], timeout: 3)
        try await navigation.waitForAppearance(.utxoSelection)
        try await Task.sleep(for: .milliseconds(300))
        let loadsBeforeBack = wallet.preparationCount

        navigation.path.removeLast()
        try await navigation.waitForAppearance(.confirm)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(navigation.path, [])
        XCTAssertEqual(wallet.preparationCount, loadsBeforeBack)
        XCTAssertNil(wallet.selectedUtxos)
        do {
            try await SendConfirmationView.requireManualCoinSelection(
                walletType: app.selectedWalletToPayFrom,
                isHardwarePayment: false,
                coinSelectionMethod: SettingsViewModel.shared.coinSelectionMethod,
                selectedUtxos: wallet.selectedUtxos
            ) {
                try await wallet.loadAvailableUtxos()
                navigation.path.append(.utxoSelection)
            }
            XCTFail("Missing coins must not continue to payment authorization")
        } catch is CancellationError {}
        try await navigation.waitForAppearance(.utxoSelection)
        let coins = [SpendableUtxo(outpoint: OutPoint(txid: String(repeating: "1", count: 64), vout: 0), valueSats: 10000)]
        wallet.selectedUtxos = coins
        navigation.path.append(.confirm)
        try await navigation.waitForAppearance(.confirm)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(wallet.feeUtxos, coins)
        wallet.feeUtxos = nil

        navigation.path.removeLast()
        try await navigation.waitForAppearance(.utxoSelection)
        navigation.path.removeLast()
        try await navigation.waitForAppearance(.confirm)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(navigation.path, [])
        XCTAssertEqual(wallet.feeUtxos, coins, "Returning to the original confirmation must calculate its fee for the selected coins")
    }

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
            await fulfillment(of: [wallet.started], timeout: 3)
            guard wallet.preparationCount > 0 else { continue }
            wallet.resume()
            await fulfillment(of: [wallet.finished, wallet.coinPrepared], timeout: 3)
            try await navigation.waitForAppearance(operation == .manualUtxos ? .utxoSelection : .confirm)

            XCTAssertEqual(wallet.successfulCoinPreparations, 1)
            XCTAssertEqual(wallet.preparationCount, wallet.wasCancelled ? 2 : 1)
            XCTAssertEqual(app.selectedWalletToPayFrom, .onchain)
            XCTAssertEqual(navigation.path, operation == .manualUtxos ? [.confirm, .utxoSelection] : [.confirm])
            if operation == .selection {
                XCTAssertNotNil(wallet.selectedUtxos)
            }
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

    func testPendingWalletSwitchResumesAfterTags() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        FeeEstimatesManager().devOverrideFeeEstimates = true
        for operation in [ControlledSendWallet.Operation.manualUtxos, .selection] {
            let wallet = ControlledSendWallet(operation: operation, suspendsResumedPreparation: true)
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
            try await Task.sleep(for: .milliseconds(100))
            app.selectedWalletToPayFrom = .onchain
            await fulfillment(of: [wallet.started], timeout: 3)

            navigation.path.append(.tag)
            try await navigation.waitForAppearance(.tag)
            wallet.resume()
            await fulfillment(of: [wallet.finished], timeout: 3)
            XCTAssertTrue(wallet.wasCancelled)
            XCTAssertNil(wallet.selectedUtxos)
            XCTAssertEqual(wallet.preparationCount, 1)
            XCTAssertEqual(navigation.path, [.confirm, .tag])

            // The resumed preparation waits until the pop back from tags has settled, so its push never overlaps that transition.
            navigation.path.removeLast()
            try await navigation.waitForAppearance(.confirm)
            await fulfillment(of: [wallet.resumedStarted], timeout: 3)
            XCTAssertEqual(wallet.preparationCount, 2)
            wallet.resume()
            await fulfillment(of: [wallet.coinPrepared], timeout: 3)
            try await navigation.waitForAppearance(operation == .manualUtxos ? .utxoSelection : .confirm)
            XCTAssertEqual(wallet.successfulCoinPreparations, 1)
            XCTAssertEqual(wallet.preparationCount, 2)
            XCTAssertEqual(app.selectedWalletToPayFrom, .onchain)
            XCTAssertEqual(navigation.path, operation == .manualUtxos ? [.confirm, .utxoSelection] : [.confirm])
            if operation == .selection {
                XCTAssertNotNil(wallet.selectedUtxos)
            }
        }
    }

    func testManualPickerBackReturnsToConfirmationAndAllowsSelectionAgain() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        FeeEstimatesManager().devOverrideFeeEstimates = true
        SettingsViewModel.shared.coinSelectionMethod = .manual
        let wallet = ControlledSendWallet(operation: .manualUtxos)
        let app = AppViewModel()
        let sheets = SheetViewModel()
        sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
        app.scannedOnchainInvoice = invoice
        app.selectedWalletToPayFrom = .lightning
        wallet.sendAmountSats = 6007
        wallet.selectedFeeRateSatsPerVByte = 2
        let navigation = SendConfirmationTestNavigation()
        let window = host(app: app, wallet: wallet, sheets: sheets,
                          path: Binding(get: { navigation.path }, set: { navigation.path = $0 }), navigation: navigation)
        defer { close(window) }
        try await navigation.waitForAppearance(.confirm)
        try await Task.sleep(for: .milliseconds(100))
        app.selectedWalletToPayFrom = .onchain
        await fulfillment(of: [wallet.started], timeout: 3)
        wallet.resume()
        await fulfillment(of: [wallet.finished], timeout: 3)
        try await navigation.waitForAppearance(.utxoSelection)

        for _ in 0 ..< 2 {
            navigation.path.removeLast()
            try await navigation.waitForAppearance(.confirm)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(navigation.path, [.confirm])
            XCTAssertNil(wallet.selectedUtxos)
            XCTAssertEqual(app.selectedWalletToPayFrom, .onchain)
            do {
                try await SendConfirmationView.requireManualCoinSelection(
                    walletType: app.selectedWalletToPayFrom,
                    isHardwarePayment: false,
                    coinSelectionMethod: SettingsViewModel.shared.coinSelectionMethod,
                    selectedUtxos: wallet.selectedUtxos
                ) {
                    try await wallet.loadAvailableUtxos()
                    navigation.path.append(.utxoSelection)
                }
                XCTFail("Returning without coins must not continue to payment authorization")
            } catch is CancellationError {}
            try await navigation.waitForAppearance(.utxoSelection)
            XCTAssertEqual(navigation.path, [.confirm, .utxoSelection])
        }
        XCTAssertEqual(wallet.preparationCount, 3)
        sheets.activeSheetConfiguration = nil
        app.resetSendState()
        wallet.resetSendState(speed: .normal)
        XCTAssertNil(wallet.selectedUtxos)
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

    func testInitialPaymentStartsOnceWhenSetupFinishesBeforeWalletSwitch() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let settings = SettingsViewModel.shared
        let pinEnabled = settings.pinEnabled
        addTeardownBlock { @MainActor in settings.pinEnabled = pinEnabled }
        settings.pinEnabled = true
        settings.requirePinForPayments = true
        settings.useBiometrics = false
        settings.coinSelectionMethod = .autopilot
        let wallet = ControlledSendWallet(operation: .selection)
        let app = AppViewModel()
        let sheets = SheetViewModel()
        sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
        app.contactPaymentContext = ContactPaymentContext(publicKey: "pubkytest", isInitialSubscriptionPayment: true)
        app.scannedOnchainInvoice = invoice
        app.selectedWalletToPayFrom = .lightning
        wallet.sendAmountSats = 6007
        wallet.selectedFeeRateSatsPerVByte = 2
        wallet.totalOnchainSats = 1_000_000
        let setup = SendConfirmationTestSetup()
        var path: [SendRoute] = []
        let window = host(
            app: app,
            wallet: wallet,
            sheets: sheets,
            path: Binding(get: { path }, set: { path = $0 }),
            setup: setup
        )
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(100))

        app.selectedWalletToPayFrom = .onchain
        await fulfillment(of: [wallet.started], timeout: 3)
        setup.isPending = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(setup.pinChecks.isEmpty)

        wallet.resume()
        await fulfillment(of: [wallet.finished], timeout: 3)
        let deadline = ContinuousClock.now + .seconds(3)
        while setup.pinChecks.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(setup.pinChecks, [false], "The payment starts once and is not cancelled while it awaits the PIN")
    }

    func testRecreatedConfirmationDoesNotAuthorizeWhilePaymentIsSubmitting() async throws {
        snapshotAppDefaultsDomain()
        snapshotAppGroupDefaults("home_screen_display_currency_code_v1", "home_screen_display_currency_symbol_v1")
        let settings = SettingsViewModel.shared
        let pinEnabled = settings.pinEnabled
        addTeardownBlock { @MainActor in settings.pinEnabled = pinEnabled }
        settings.pinEnabled = true
        settings.requirePinForPayments = true
        settings.useBiometrics = false
        settings.coinSelectionMethod = .autopilot
        let app = AppViewModel()
        let wallet = WalletViewModel()
        let sheets = SheetViewModel()
        sheets.activeSheetConfiguration = SheetConfiguration(id: .send, data: nil)
        app.contactPaymentContext = ContactPaymentContext(publicKey: "pubkytest", isInitialSubscriptionPayment: true)
        app.scannedLightningInvoice = LightningInvoice(
            bolt11: "test-invoice", paymentHash: Data(), amountSatoshis: 6007,
            timestampSeconds: 0, expirySeconds: 0, isExpired: false,
            description: nil, networkType: .regtest, payeeNodeId: nil
        )
        app.selectedWalletToPayFrom = .lightning
        wallet.sendAmountSats = 6007
        wallet.totalLightningSats = 1_000_000
        let setup = SendConfirmationTestSetup()
        setup.isPending = false
        var isSubmittingPayment = true
        var path: [SendRoute] = []

        for _ in 0 ..< 2 {
            let window = host(
                app: app,
                wallet: wallet,
                sheets: sheets,
                path: Binding(get: { path }, set: { path = $0 }),
                setup: setup,
                isSubmittingPayment: Binding(get: { isSubmittingPayment }, set: { isSubmittingPayment = $0 })
            )
            try await Task.sleep(for: .milliseconds(500))
            close(window)
        }

        XCTAssertTrue(setup.pinChecks.isEmpty, "Restoring an in-flight payment must not request authorization again")
        XCTAssertTrue(path.isEmpty, "Ignoring the duplicate entry must preserve the original payment's navigation")
        XCTAssertTrue(isSubmittingPayment, "The original payment owns the retained submission flag")
    }

    private func host(
        app: AppViewModel,
        wallet: WalletViewModel,
        sheets: SheetViewModel,
        path: Binding<[SendRoute]>,
        navigation: SendConfirmationTestNavigation? = nil,
        setup: SendConfirmationTestSetup? = nil,
        confirmationIsRoot: Bool = false,
        isSubmittingPayment: Binding<Bool> = .constant(false)
    ) -> UIWindow {
        let hwSend = HwSendCoordinator()
        let makeConfirmation = { (isSetupPending: Bool) in
            SendConfirmationView(
                navigationPath: path,
                isSubmittingPayment: isSubmittingPayment,
                hwSend: hwSend,
                requestPinCheck: {
                    guard let setup else {
                        XCTFail("Preparing confirmation must not authorize a payment")
                        return false
                    }
                    setup.pinChecks.append(Task.isCancelled)
                    return false
                },
                prepareIncomingPaymentRequest: {
                    XCTFail("Preparing confirmation must not submit a payment request")
                },
                routingCacheResetAttempted: false,
                isSetupPending: isSetupPending
            )
        }
        let confirmation = SetupObservingConfirmation(setup: setup, makeConfirmation: makeConfirmation)
        let view = Group {
            if let navigation {
                @Bindable var navigation = navigation
                NavigationStack(path: $navigation.path) {
                    Group {
                        if confirmationIsRoot {
                            confirmation
                                .onAppear { navigation.visibleRoutes.insert(.confirm) }
                                .onDisappear { navigation.visibleRoutes.remove(.confirm) }
                        } else {
                            Color.clear
                        }
                    }
                    .navigationDestination(for: SendRoute.self) { route in
                        Group {
                            switch route {
                            case .confirm: confirmation
                            case .feeRate: SendFeeRate(navigationPath: $navigation.path, hwSend: hwSend)
                            case .feeCustom: SendFeeCustom(navigationPath: $navigation.path, hwSend: hwSend)
                            case .tag: SendTagScreen(navigationPath: $navigation.path)
                            case .utxoSelection: SendUtxoSelectionView(navigationPath: $navigation.path)
                            default: Color.clear
                            }
                        }
                        .onAppear { navigation.visibleRoutes.insert(route) }
                        .onDisappear {
                            navigation.visibleRoutes.remove(route)
                            if route == .confirm {
                                navigation.confirmationDisappearances += 1
                            }
                        }
                    }
                }
                .transaction { transaction in
                    // Avoid an automatic push racing an animated pop in this test host.
                    transaction.disablesAnimations = true
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

    private func onchainRequest(
        isQuoted: Bool = true,
        acceptsLightning: Bool = false,
        rates: [ConversionRate] = [
            ConversionRate(asset: "btc", value: "0.00001"),
            ConversionRate(asset: "btc-lightning", value: "0.00002"),
        ],
        deadline: Paykit.PaymentDeadline? = nil
    ) throws -> PaykitPaymentRequest {
        let record = try PaymentRequestRecord(
            counterparty: "pubkycontact",
            paymentRequestId: "550e8400-e29b-41d4-a716-446655440000",
            localRole: .payer,
            state: .proposed,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            proposalAppId: "bitkit",
            payerAppId: nil,
            executionClaimAppId: nil,
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: isQuoted ? "2.50" : "0.000025", asset: isQuoted ? "usd" : "btc"),
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: nil,
                recurrence: nil,
                acceptedPaymentEndpointIdentifiers: acceptsLightning ? [
                    PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue,
                    PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                ] : [PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue],
                paymentEndpoints: nil,
                requiredAppId: "bitkit",
                conversion: isQuoted ? .fixed(rates: rates) : nil,
                paymentDeadline: deadline,
                metadata: PrivateJsonObject(text: "{}")
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            conversionQuotes: [],
            paymentProofs: [],
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: "2027-01-15T08:00:00Z",
            invalidReason: nil
        )
        return try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date(timeIntervalSince1970: 0)))
    }

    private var invoice: OnChainInvoice {
        OnChainInvoice(address: "bcrt1qexample", amountSatoshis: 6007, label: nil, message: nil, params: nil)
    }
}

@Observable
@MainActor
private final class SendConfirmationTestSetup {
    var isPending = true
    /// Whether the payment task was cancelled at each PIN request.
    var pinChecks: [Bool] = []
}

private struct SetupObservingConfirmation: View {
    let setup: SendConfirmationTestSetup?
    let makeConfirmation: (Bool) -> SendConfirmationView

    var body: some View {
        makeConfirmation(setup?.isPending ?? false)
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
    let resumedStarted = XCTestExpectation(description: "Resumed send preparation suspended")
    let coinPrepared = XCTestExpectation(description: "Current send coin preparation applied")
    private let operation: Operation
    private let fails: Bool
    private let suspendsResumedPreparation: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false
    private(set) var preparationCount = 0
    private(set) var successfulCoinPreparations = 0
    private(set) var selectedAlgorithm: CoinSelectionAlgorithm?
    var feeUtxos: [SpendableUtxo]?
    private(set) var routingAmounts: [UInt64?] = []

    init(operation: Operation, fails: Bool = false, suspendsResumedPreparation: Bool = false) {
        self.operation = operation
        self.fails = fails
        self.suspendsResumedPreparation = suspendsResumedPreparation
        super.init(
            transferService: TransferService(lightningService: .shared),
            sheetViewModel: SheetViewModel(),
            feeEstimatesManager: FeeEstimatesManager()
        )
    }

    override func setFeeRate(speed: TransactionSpeed, isCurrentSend: () -> Bool = { true }) async throws {
        if operation == .fee {
            try await suspend()
        }
        guard !Task.isCancelled, isCurrentSend() else { throw CancellationError() }
        selectedFeeRateSatsPerVByte = 2
    }

    override func loadAvailableUtxos(isCurrentSend: () -> Bool = { true }) async throws {
        try await suspend()
        guard !Task.isCancelled, isCurrentSend() else { throw CancellationError() }
        successfulCoinPreparations += 1
        availableUtxos = []
        coinPrepared.fulfill()
    }

    override func setUtxoSelection(
        coinSelectionAlgorythm: CoinSelectionAlgorithm,
        isCurrentSend: () -> Bool = { true },
        listSpendable: (() async throws -> [SpendableUtxo])? = nil,
        selectForAmount: ((UInt64, UInt32, CoinSelectionAlgorithm) async throws -> [SpendableUtxo])? = nil
    ) async throws {
        selectedAlgorithm = coinSelectionAlgorythm
        if operation == .selection {
            try await suspend()
        }
        guard !Task.isCancelled, isCurrentSend() else { throw CancellationError() }
        successfulCoinPreparations += 1
        selectedUtxos = []
        coinPrepared.fulfill()
    }

    override func calculateTotalFee(address: String, amountSats: UInt64, satsPerVByte: UInt32,
                                    utxosToSpend: [SpendableUtxo]? = nil) async throws -> UInt64
    {
        feeUtxos = utxosToSpend
        return 10
    }

    override func refreshRoutingFeeEstimate(bolt11: String, amountSats: UInt64?) async {
        routingAmounts.append(amountSats)
        routingFeeEstimateSats = 10
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func suspend() async throws {
        preparationCount += 1
        if preparationCount == 2, suspendsResumedPreparation {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                resumedStarted.fulfill()
            }
            return
        }
        if preparationCount == 1 {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
            wasCancelled = Task.isCancelled
            finished.fulfill()
        }
        if fails {
            throw AppError(message: "UTXO selection unavailable", debugMessage: nil)
        }
    }
}
