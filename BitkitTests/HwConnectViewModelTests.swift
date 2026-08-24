@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class HwConnectViewModelTests: XCTestCase {
    private var service: FakeHwConnectService!
    private var sut: HwConnectViewModel!

    override func setUp() {
        super.setUp()
        service = FakeHwConnectService()
        sut = HwConnectViewModel(service: service)
    }

    override func tearDown() {
        sut.reset()
        sut = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Searching

    func testOnIntroContinueSearchesThenAdvancesToFoundWithFirstDevice() async {
        service.nearbyDevices = [makeDevice(id: "dev1", model: "Safe 3")]

        sut.onIntroContinue()

        await waitUntil { self.sut.phase == .found }
        XCTAssertEqual(sut.phase, .found)
        XCTAssertEqual(sut.foundDevice?.id, "dev1")
        XCTAssertEqual(sut.foundDeviceModel, "Trezor Safe 3")
        XCTAssertNil(sut.errorMessage)
    }

    func testOnIntroContinueSurfacesSearchFailureWhileSearching() async {
        service.scanError = TestError.stub

        sut.onIntroContinue()

        await waitUntil { self.sut.errorMessage != nil }
        XCTAssertEqual(sut.phase, .searching)
        XCTAssertEqual(sut.errorMessage, t("hardware__search_error"))
    }

    // MARK: - Connect

    func testOnConnectConnectsFoundDeviceAndAdvancesToPaired() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(deviceId: "dev1", walletId: standardWalletId, name: "Trezor Safe 3"))

        sut.onConnect()

        await waitUntil { self.sut.phase == .paired }
        XCTAssertEqual(service.connectedDeviceIds, ["dev1"])
        XCTAssertEqual(sut.pairedDeviceId, "dev1")
        XCTAssertEqual(sut.deviceName, "Trezor Safe 3")
        XCTAssertEqual(sut.labelInput, "Trezor Safe 3")
        XCTAssertFalse(sut.isConnecting)
    }

    func testOnConnectSurfacesRealErrorMessageAndReturnsToFound() async {
        await givenDeviceFound()
        let realMessage = t("hardware__pairing_code_invalid")
        // Use the module-qualified type: `Errors.swift` is also compiled into the test target, so an
        // unqualified `AppError` here is a distinct `BitkitTests.AppError` that the view model's
        // `Bitkit.AppError` cast would reject. Production throws `Bitkit.AppError`, so mirror that.
        service.connectResult = .failure(Bitkit.AppError(message: realMessage, debugMessage: nil))

        sut.onConnect()

        await waitUntil { self.sut.errorMessage != nil }
        XCTAssertEqual(sut.phase, .found)
        XCTAssertFalse(sut.isConnecting)
        XCTAssertEqual(sut.errorMessage, realMessage)
        XCTAssertEqual(sut.foundDevice?.id, "dev1")
    }

    func testOnConnectFallsBackToGenericErrorForNonAppError() async {
        await givenDeviceFound()
        service.connectResult = .failure(TestError.stub)

        sut.onConnect()

        await waitUntil { self.sut.errorMessage != nil }
        XCTAssertEqual(sut.phase, .found)
        XCTAssertFalse(sut.isConnecting)
        XCTAssertEqual(sut.errorMessage, t("hardware__connect_error"))
    }

    // MARK: - Pairing code

    func testPairingCodeRequestSurfacesInlinePairCodeStepWhileConnecting() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(deviceId: "dev1", walletId: standardWalletId, name: "Trezor Safe 3"))

        // onConnect flips isConnecting synchronously; the connect Task is queued but not yet run,
        // so the pairing-code request lands mid-connect exactly as it would on device.
        sut.onConnect()
        XCTAssertTrue(sut.isConnecting)
        sut.onPairingCodeRequested()

        XCTAssertEqual(sut.phase, .pairCode)
    }

    func testPairingCodeRequestIgnoredWhenNotConnecting() {
        sut.onPairingCodeRequested()
        XCTAssertEqual(sut.phase, .intro)
    }

    // MARK: - Paired

    func testConnectedWalletUpdatesBalanceOnPairedStep() async {
        await givenDevicePaired()

        sut.onWalletsUpdated([makeWallet(id: standardWalletId, name: "Trezor Safe 3", balance: 10_562_411)])

        XCTAssertEqual(sut.balanceSats, 10_562_411)
        XCTAssertEqual(sut.deviceName, "Trezor Safe 3")
    }

    /// A device whose session did not resolve reports every one of its identities as connected, so
    /// adopting one would show a sibling's balance and rename it on Finish.
    func testDoesNotAdoptAnIdentityWhenTheDeviceHoldsSeveralAndTheSessionIsUnresolved() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(deviceId: "dev1", walletId: nil, name: "Trezor Safe 3"))
        sut.onConnect()
        await waitUntil { self.sut.phase == .paired }

        sut.onWalletsUpdated([
            makeWallet(id: standardWalletId, name: "Standard", balance: 30000),
            makeWallet(id: hiddenWalletId, name: "Hidden", balance: 20000),
        ])

        XCTAssertNil(sut.pairedWalletId)
        XCTAssertEqual(sut.balanceSats, 0)
        XCTAssertEqual(sut.deviceName, "Trezor Safe 3", "the device's own name stands until an identity resolves")
    }

    func testAdoptsTheOnlyIdentityOfTheDeviceWhenTheSessionIsUnresolved() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(deviceId: "dev1", walletId: nil, name: "Trezor Safe 3"))
        sut.onConnect()
        await waitUntil { self.sut.phase == .paired }

        sut.onWalletsUpdated([makeWallet(id: standardWalletId, name: "Standard", balance: 30000)])

        XCTAssertEqual(sut.pairedWalletId, standardWalletId)
        XCTAssertEqual(sut.balanceSats, 30000)
    }

    /// One identity reading as connected means the session resolved after the connect returned.
    func testAdoptsTheIdentityThatResolvedAfterTheConnect() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(deviceId: "dev1", walletId: nil, name: "Trezor Safe 3"))
        sut.onConnect()
        await waitUntil { self.sut.phase == .paired }

        sut.onWalletsUpdated([
            makeWallet(id: standardWalletId, name: "Standard", balance: 30000, isConnected: false),
            makeWallet(id: hiddenWalletId, name: "Hidden", balance: 20000, isConnected: true),
        ])

        XCTAssertEqual(sut.pairedWalletId, hiddenWalletId)
        XCTAssertEqual(sut.balanceSats, 20000)
    }

    func testOnLabelChangeCapsTheLabelInput() {
        sut.onLabelChange(String(repeating: "a", count: 51))
        XCTAssertEqual(sut.labelInput, String(repeating: "a", count: 50))
    }

    func testOnFinishPersistsEditedLabelAndFinishes() async {
        await givenDevicePaired()
        sut.onLabelChange("My Cold Wallet")
        var finished = false
        sut.onFinished = { finished = true }

        sut.onFinish()

        XCTAssertEqual(service.setLabelCalls.count, 1)
        XCTAssertEqual(service.setLabelCalls.first?.walletId, standardWalletId)
        XCTAssertEqual(service.setLabelCalls.first?.label, "My Cold Wallet")
        XCTAssertTrue(finished)
    }

    // MARK: - Passphrase wallets

    func testPassphraseSubmitWatchesTheHiddenWalletAndAdvances() async {
        await givenDevicePaired()
        service.passphraseResult = .success(hiddenWalletId)
        sut.onPassphraseClick()
        sut.onPassphraseChange("correct horse")

        sut.onPassphraseSubmit()

        await waitUntil { self.sut.phase == .passphrasePaired }
        XCTAssertEqual(service.passphraseCalls.first?.passphrase, "correct horse")
        XCTAssertEqual(sut.pairedWalletId, hiddenWalletId)
        XCTAssertTrue(sut.passphraseInput.isEmpty, "the passphrase lives in the device session, never in Bitkit")
        XCTAssertEqual(sut.balanceSats, 0, "the new identity starts empty until its watcher reports")
    }

    /// A brand-new identity has no label of its own, and the label of whichever wallet happened to be
    /// open before it is not its name.
    func testPassphraseWalletIsPrefilledWithTheDeviceNameNotTheRenamedWalletsLabel() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(
            deviceId: "dev1",
            walletId: standardWalletId,
            name: "Standard Funds", // the standard wallet was renamed by the user
            deviceDefaultName: "Trezor Safe 3"
        ))
        sut.onConnect()
        await waitUntil { self.sut.phase == .paired }
        XCTAssertEqual(sut.labelInput, "Standard Funds", "the paired wallet keeps its own label")

        service.passphraseResult = .success(hiddenWalletId)
        sut.onPassphraseClick()
        sut.onPassphraseChange("correct horse")
        sut.onPassphraseSubmit()
        await waitUntil { self.sut.phase == .passphrasePaired }

        XCTAssertEqual(sut.deviceName, "Trezor Safe 3")
        XCTAssertEqual(sut.labelInput, "Trezor Safe 3")
    }

    /// A hidden wallet being added back already carries the name kept through its removal, so it must
    /// not sit on the device's own name for as long as the wallet takes to reach the published list.
    func testReaddedPassphraseWalletShowsItsStoredNameImmediately() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(
            deviceId: "dev1",
            walletId: standardWalletId,
            name: "Trezor Safe 3",
            deviceDefaultName: "Trezor Safe 3"
        ))
        sut.onConnect()
        await waitUntil { self.sut.phase == .paired }

        service.passphraseResult = .success(hiddenWalletId)
        service.storedNames[hiddenWalletId] = "Pass B"
        sut.onPassphraseClick()
        sut.onPassphraseChange("correct horse")
        sut.onPassphraseSubmit()
        await waitUntil { self.sut.phase == .passphrasePaired }

        XCTAssertEqual(sut.deviceName, "Pass B")
        XCTAssertEqual(sut.labelInput, "Pass B")
    }

    /// The stored name is the prefill, so a wallet emission landing afterwards must not reset the
    /// field the user may already be editing.
    func testAReaddedPassphraseWalletsNameSurvivesALaterWalletEmission() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(
            deviceId: "dev1",
            walletId: standardWalletId,
            name: "Trezor Safe 3",
            deviceDefaultName: "Trezor Safe 3"
        ))
        sut.onConnect()
        await waitUntil { self.sut.phase == .paired }

        service.passphraseResult = .success(hiddenWalletId)
        service.storedNames[hiddenWalletId] = "Pass B"
        sut.onPassphraseClick()
        sut.onPassphraseChange("correct horse")
        sut.onPassphraseSubmit()
        await waitUntil { self.sut.phase == .passphrasePaired }

        sut.onWalletsUpdated([makeWallet(id: hiddenWalletId, name: "Pass B", balance: 42)])

        XCTAssertEqual(sut.labelInput, "Pass B")
        XCTAssertEqual(sut.balanceSats, 42)
    }

    func testPassphraseFailureReportsInlineAndKeepsNoPassphrase() async {
        await givenDevicePaired()
        service.passphraseResult = .failure(HwPassphraseError.alreadyAdded)
        sut.onPassphraseClick()
        sut.onPassphraseChange("already used")

        sut.onPassphraseSubmit()

        await waitUntil { self.sut.errorMessage != nil }
        XCTAssertEqual(sut.phase, .passphrase)
        XCTAssertEqual(sut.errorMessage, t("hardware__passphrase_duplicate"))
        XCTAssertTrue(sut.passphraseInput.isEmpty)
        XCTAssertFalse(sut.isSubmittingPassphrase)
    }

    func testPassphraseProtectionDisabledIsReportedInItsOwnWords() async {
        await givenDevicePaired()
        service.passphraseResult = .failure(HwPassphraseError.protectionDisabled)
        sut.onPassphraseClick()
        sut.onPassphraseChange("anything")

        sut.onPassphraseSubmit()

        await waitUntil { self.sut.errorMessage != nil }
        XCTAssertEqual(sut.errorMessage, t("hardware__passphrase_disabled"))
    }

    /// Each identity is labelled on its own paired step, so the one being left must be saved first.
    func testMovingToThePassphraseStepPersistsTheLabelOfTheWalletBeingLeft() async {
        await givenDevicePaired()
        sut.onLabelChange("Standard Funds")

        sut.onPassphraseClick()

        XCTAssertEqual(sut.phase, .passphrase)
        XCTAssertEqual(service.setLabelCalls.count, 1)
        XCTAssertEqual(service.setLabelCalls.first?.walletId, standardWalletId)
        XCTAssertEqual(service.setLabelCalls.first?.label, "Standard Funds")
    }

    func testBackFromThePassphraseStepDropsWhatWasTyped() async {
        await givenDevicePaired()
        sut.onPassphraseClick()
        sut.onPassphraseChange("secret")

        sut.onPassphraseBack()

        XCTAssertEqual(sut.phase, .paired)
        XCTAssertTrue(sut.passphraseInput.isEmpty)
    }

    func testDismissingTheSheetDropsTheEnteredPassphrase() async {
        await givenDevicePaired()
        sut.onPassphraseClick()
        sut.onPassphraseChange("secret")

        sut.reset()

        XCTAssertTrue(sut.passphraseInput.isEmpty)
    }

    /// A device holding several wallets shares one transport id, so the paired step must follow the
    /// identity being paired and wait for it rather than adopting a sibling's name and balance.
    func testPairedStepWaitsForTheIdentityBeingPaired() async {
        await givenDevicePaired()
        service.passphraseResult = .success(hiddenWalletId)
        sut.onPassphraseClick()
        sut.onPassphraseChange("correct horse")
        sut.onPassphraseSubmit()
        await waitUntil { self.sut.phase == .passphrasePaired }

        // The standard wallet is still the only one published.
        sut.onWalletsUpdated([makeWallet(id: standardWalletId, name: "Standard", balance: 30000)])
        XCTAssertEqual(sut.balanceSats, 0, "a sibling wallet's balance is not this wallet's")

        sut.onWalletsUpdated([
            makeWallet(id: standardWalletId, name: "Standard", balance: 30000),
            makeWallet(id: hiddenWalletId, name: "Hidden", balance: 20000, isConnected: true),
        ])
        XCTAssertEqual(sut.balanceSats, 20000)
        XCTAssertEqual(sut.deviceName, "Hidden")
    }

    func testTypedLabelSurvivesAWalletEmissionArrivingAfterwards() async {
        await givenDevicePaired()
        sut.onLabelChange("My Cold Wallet")

        sut.onWalletsUpdated([makeWallet(id: standardWalletId, name: "Trezor Safe 3", balance: 42000)])

        XCTAssertEqual(sut.labelInput, "My Cold Wallet")
    }

    func testFinishingLabelsTheIdentityThatWasPaired() async {
        await givenDevicePaired()
        service.passphraseResult = .success(hiddenWalletId)
        sut.onPassphraseClick()
        sut.onPassphraseChange("correct horse")
        sut.onPassphraseSubmit()
        await waitUntil { self.sut.phase == .passphrasePaired }
        sut.onLabelChange("Hidden Funds")

        sut.onFinish()

        XCTAssertEqual(service.setLabelCalls.last?.walletId, hiddenWalletId)
        XCTAssertEqual(service.setLabelCalls.last?.label, "Hidden Funds")
    }

    /// The device is paired either way, so the flow finishes instead of dropping out of it.
    func testFinishingCompletesEvenWhenNoIdentityResolved() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(deviceId: "dev1", walletId: nil, name: "Trezor Safe 3"))
        sut.onConnect()
        await waitUntil { self.sut.phase == .paired }
        var finished = false
        sut.onFinished = { finished = true }

        sut.onFinish()

        XCTAssertTrue(service.setLabelCalls.isEmpty)
        XCTAssertTrue(finished)
    }

    // MARK: - Helpers

    private func givenDeviceFound() async {
        service.nearbyDevices = [makeDevice(id: "dev1", model: "Safe 3")]
        sut.onIntroContinue()
        await waitUntil { self.sut.phase == .found }
    }

    private func givenDevicePaired() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(deviceId: "dev1", walletId: standardWalletId, name: "Trezor Safe 3"))
        sut.onConnect()
        await waitUntil { self.sut.phase == .paired }
    }

    // MARK: - Paired step name

    /// Re-adding a removed wallet is the case the published wallet list cannot answer: the wallet is
    /// not in it yet, but the entry pairing just wrote already carries the name kept for it.
    func testPairedNameUsesTheStoredLabelOfAWalletMissingFromTheWalletList() {
        let name = TrezorHwConnectService.pairedName(
            walletId: standardWalletId,
            storedEntries: [makeStoredEntry(walletId: standardWalletId, customLabel: "No Pass")],
            deviceDefaultName: "Trezor T"
        )

        XCTAssertEqual(name, "No Pass")
    }

    func testPairedNameFallsBackToTheDeviceNameWhenTheWalletWasNeverNamed() {
        let name = TrezorHwConnectService.pairedName(
            walletId: standardWalletId,
            storedEntries: [makeStoredEntry(walletId: standardWalletId, customLabel: nil)],
            deviceDefaultName: "Trezor T"
        )

        XCTAssertEqual(name, "Trezor T")
    }

    /// A brand-new passphrase wallet has no entry of its own yet, and must not borrow the name of the
    /// identity that happened to be open before it.
    func testPairedNameIgnoresAnotherIdentitysLabel() {
        let name = TrezorHwConnectService.pairedName(
            walletId: hiddenWalletId,
            storedEntries: [makeStoredEntry(walletId: standardWalletId, customLabel: "No Pass")],
            deviceDefaultName: "Trezor T"
        )

        XCTAssertEqual(name, "Trezor T")
    }

    func testPairedNameFallsBackToTheDeviceNameBeforeTheIdentityResolves() {
        let name = TrezorHwConnectService.pairedName(
            walletId: nil,
            storedEntries: [makeStoredEntry(walletId: standardWalletId, customLabel: "No Pass")],
            deviceDefaultName: "Trezor T"
        )

        XCTAssertEqual(name, "Trezor T")
    }

    private func makeStoredEntry(walletId: String, customLabel: String?) -> TrezorKnownDevice {
        TrezorKnownDevice(
            id: "dev1",
            name: "Trezor",
            path: "ble://dev1",
            transportType: "bluetooth",
            lastConnectedAt: Date(timeIntervalSince1970: 0),
            xpubs: ["nativeSegwit": "z\(walletId)"],
            customLabel: customLabel,
            walletId: walletId
        )
    }

    private func makeDevice(id: String, model: String?) -> TrezorDeviceInfo {
        TrezorDeviceInfo(
            id: id,
            transportType: .bluetooth,
            name: nil,
            path: "ble:\(id)",
            label: nil,
            model: model,
            isBootloader: false
        )
    }

    private let standardWalletId = "trezor:standard"
    private let hiddenWalletId = "trezor:hidden"

    private func makeWallet(
        id: String,
        name: String,
        balance: UInt64,
        deviceIds: Set<String> = ["dev1"],
        isConnected: Bool = true
    ) -> HwWallet {
        HwWallet(
            id: id,
            walletId: id,
            name: name,
            model: nil,
            isConnected: isConnected,
            balanceSats: balance,
            deviceIds: deviceIds
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum TestError: Error {
    case stub
}

@MainActor
private final class FakeHwConnectService: HwConnectServicing {
    var nearbyDevices: [TrezorDeviceInfo] = []
    var scanError: Error?
    var connectResult: Result<HwConnectResult, Error> = .failure(TestError.stub)
    var passphraseResult: Result<String, Error> = .failure(TestError.stub)
    var storedNames: [String: String] = [:]

    private(set) var scanCount = 0
    private(set) var connectedDeviceIds: [String] = []
    private(set) var passphraseCalls: [(deviceId: String, passphrase: String)] = []
    private(set) var setLabelCalls: [(walletId: String, label: String)] = []
    private(set) var cancelPairingCount = 0

    func scanForDevices() async throws -> [TrezorDeviceInfo] {
        scanCount += 1
        if let scanError { throw scanError }
        return nearbyDevices
    }

    func connect(to device: TrezorDeviceInfo) async throws -> HwConnectResult {
        connectedDeviceIds.append(device.id)
        return try connectResult.get()
    }

    func connectWithPassphrase(deviceId: String, passphrase: String) async throws -> String {
        passphraseCalls.append((deviceId, passphrase))
        return try passphraseResult.get()
    }

    func storedName(forWallet walletId: String) -> String? {
        storedNames[walletId]
    }

    func setWalletLabel(walletId: String, label: String) {
        setLabelCalls.append((walletId, label))
    }

    func cancelPairingCode() {
        cancelPairingCount += 1
    }
}
