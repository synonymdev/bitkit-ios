@testable import Bitkit
import LDKNode
import SwiftUI
import XCTest

final class SendConfirmationSwipeTests: XCTestCase {
    @MainActor
    func testRestoredLoadingSwipeKeepsItsSpinnerInTheKnob() async throws {
        let confirmation = NavigationStack(path: .constant([true])) {
            Color.black
                .navigationDestination(for: Bool.self) { _ in
                    SwipeButton(title: "Swipe To Pay", accentColor: Color(red: 1, green: 0.4, blue: 0), isLoading: true) {
                        XCTFail("Restoring a loading control must not start another operation")
                    }
                    .frame(width: 343, height: 76)
                }
        }
        let controller = UIHostingController(rootView: AnyView(confirmation))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        try await assertSpinnerIsInsideKnob(window, name: "initial-loading-confirmation")
        controller.rootView = AnyView(Color.black)
        try await Task.sleep(for: .milliseconds(300))
        controller.rootView = AnyView(confirmation)
        try await assertSpinnerIsInsideKnob(window, name: "restored-loading-confirmation")
    }

    @MainActor
    private func assertSpinnerIsInsideKnob(_ window: UIWindow, name: String) async throws {
        try await Task.sleep(for: .milliseconds(1500))
        let view = try XCTUnwrap(window.rootViewController?.view)
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let snapshot = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(snapshot.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var orangePoints: [CGPoint] = []
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                let offset = (y * image.width + x) * 4
                if pixels[offset] > 200, pixels[offset + 1] > 60, pixels[offset + 1] < 160, pixels[offset + 2] < 60 {
                    orangePoints.append(CGPoint(x: x, y: y))
                }
            }
        }
        let centerX = try Int((XCTUnwrap(orangePoints.map(\.x).min()) + XCTUnwrap(orangePoints.map(\.x).max())) / 2)
        let centerY = try Int((XCTUnwrap(orangePoints.map(\.y).min()) + XCTUnwrap(orangePoints.map(\.y).max())) / 2)
        var darkPixels = 0
        for y in centerY - 16 ..< centerY + 16 {
            for x in centerX - 16 ..< centerX + 16 {
                let offset = (y * image.width + x) * 4
                if pixels[offset] < 80, pixels[offset + 1] < 80, pixels[offset + 2] < 80 {
                    darkPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(darkPixels, 20, "The loading spinner must remain centered in its knob after navigation restoration")
    }

    func testManualSelectionFailureStopsSubmissionAndAllowsRetry() async throws {
        enum SelectionError: Error { case unavailable }
        var attempts = 0
        var openedSelection = false
        for shouldFail in [true, false] {
            do {
                try await SendConfirmationView.requireManualCoinSelection(
                    walletType: .onchain,
                    isHardwarePayment: false,
                    coinSelectionMethod: .manual,
                    selectedUtxos: nil
                ) {
                    attempts += 1
                    if shouldFail {
                        throw SelectionError.unavailable
                    }
                    openedSelection = true
                }
                XCTFail("Manual selection must stop before payment authorization")
            } catch SelectionError.unavailable {
                XCTAssertTrue(shouldFail)
            } catch is CancellationError {
                XCTAssertFalse(shouldFail)
            }
            XCTAssertEqual(openedSelection, !shouldFail)
        }
        XCTAssertEqual(attempts, 2)
    }

    func testManualSelectionInterruptsSubmissionUntilCoinsAreChosen() async throws {
        for selectedUtxos: [SpendableUtxo]? in [nil, []] {
            var openedSelection = false
            do {
                try await SendConfirmationView.requireManualCoinSelection(
                    walletType: .onchain,
                    isHardwarePayment: false,
                    coinSelectionMethod: .manual,
                    selectedUtxos: selectedUtxos
                ) {
                    openedSelection = true
                }
                XCTFail("Missing manual coins must stop before payment authorization")
            } catch is CancellationError {} catch {
                XCTFail("Expected cancellation to reset the swipe, got \(error)")
            }
            XCTAssertTrue(openedSelection)
        }
    }

    func testCoinSelectionGuardPreservesPreparedAndAutomaticPayments() async throws {
        let coins = [SpendableUtxo(outpoint: OutPoint(txid: String(repeating: "1", count: 64), vout: 0), valueSats: 10000)]
        let cases: [(WalletType, Bool, CoinSelectionMethod, [SpendableUtxo]?)] = [
            (.onchain, false, .manual, coins),
            (.onchain, false, .autopilot, nil),
            (.lightning, false, .manual, nil),
            (.onchain, true, .manual, nil),
        ]
        for (walletType, isHardwarePayment, method, selectedUtxos) in cases {
            try await SendConfirmationView.requireManualCoinSelection(
                walletType: walletType,
                isHardwarePayment: isHardwarePayment,
                coinSelectionMethod: method,
                selectedUtxos: selectedUtxos
            ) {
                XCTFail("Prepared coins, automatic mode, Lightning and hardware must keep their existing payment path")
            }
        }
    }

    func testWalletPreparationKeepsSwipeDisabledWithKnownFees() {
        XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: 5,
            isPreparingWallet: true
        ))
    }

    func testPreparingRequestKeepsSwipeDisabledAndLoadingWithKnownFees() {
        for walletType in [WalletType.lightning, .onchain] {
            XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
                walletType: walletType,
                isHardwarePayment: false,
                isHardwareConfirmationUnavailable: false,
                feeRate: 5,
                isPreparingRequest: true
            ))
        }
        XCTAssertTrue(SendConfirmationView.isSwipeLoading(
            hasStartedAutomaticPayment: false,
            isFeeRateMissing: false,
            feeRateLoadFailed: false,
            isPreparingRequest: true
        ))
    }

    func testOnchainPaymentWithoutFeeRateDisablesSwipe() {
        XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: nil
        ))
    }

    func testOnchainPaymentWithFeeRateEnablesSwipe() {
        XCTAssertFalse(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: 5
        ))
    }

    func testLightningPaymentNeverWaitsForFeeRate() {
        XCTAssertFalse(SendConfirmationView.isSwipeDisabled(
            walletType: .lightning,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: nil
        ))
    }

    func testHardwarePaymentKeepsItsOwnRule() {
        XCTAssertFalse(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: true,
            isHardwareConfirmationUnavailable: false,
            feeRate: nil
        ))
        XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: true,
            isHardwareConfirmationUnavailable: true,
            feeRate: 5
        ))
    }

    func testSwipeShowsItsSpinnerWhileTheFeeRateLoads() {
        XCTAssertTrue(SendConfirmationView.isSwipeLoading(
            hasStartedAutomaticPayment: false,
            isFeeRateMissing: true,
            feeRateLoadFailed: false
        ))
    }

    func testManualPaymentKeepsTheSwipeBusyWhenConfirmationIsRecreated() {
        XCTAssertTrue(SendConfirmationView.isSwipeLoading(
            hasStartedAutomaticPayment: false,
            isFeeRateMissing: false,
            feeRateLoadFailed: false,
            isSubmittingPayment: true
        ))
        XCTAssertFalse(SendConfirmationView.isSwipeLoading(
            hasStartedAutomaticPayment: false,
            isFeeRateMissing: false,
            feeRateLoadFailed: false,
            isSubmittingPayment: false
        ))
    }

    func testSwipeStopsItsSpinnerOnceTheFeeRateLoadFailed() {
        XCTAssertFalse(SendConfirmationView.isSwipeLoading(
            hasStartedAutomaticPayment: false,
            isFeeRateMissing: true,
            feeRateLoadFailed: true
        ))
        XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
            walletType: .onchain,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: nil
        ))
    }

    func testAutomaticPaymentKeepsTheSpinnerWhateverTheFeeRateState() {
        for feeRateLoadFailed in [false, true] {
            XCTAssertTrue(SendConfirmationView.isSwipeLoading(
                hasStartedAutomaticPayment: true,
                isFeeRateMissing: true,
                feeRateLoadFailed: feeRateLoadFailed
            ))
        }
    }

    func testFeeRateIsOnlyMissingForSoftwareOnchainPayments() {
        for walletType in [WalletType.lightning, .onchain] {
            for isHardwarePayment in [false, true] {
                for feeRate in [nil, UInt32(5)] {
                    XCTAssertEqual(
                        SendConfirmationView.isFeeRateMissing(walletType: walletType, isHardwarePayment: isHardwarePayment, feeRate: feeRate),
                        walletType == .onchain && !isHardwarePayment && feeRate == nil
                    )
                }
            }
        }
    }
}
