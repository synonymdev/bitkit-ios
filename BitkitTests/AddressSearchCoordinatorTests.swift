@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class AddressSearchCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AddressSearchCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testCompanionReceiveAddressAfterChangeUsesSeparateSearchWindow() async throws {
        let key = "addressSearch_lastUsedReceiveIndex_nativeSegwit_account3"
        defaults.set(400, forKey: key)
        let search = AddressSearchCoordinator(
            defaults: defaults,
            listAccounts: { [OnchainWalletAccount(addressType: .nativeSegwit, accountIndex: 3)] },
            deriveAddresses: { account, keychain, start, count in
                XCTAssertEqual(count, 200)
                if account.accountIndex == 3, keychain == .external, start == 1200 {
                    return ["server-receive"]
                }
                return []
            }
        )
        let result = try await search.runAddressSearch(
            details: details(["unrelated-change", "server-receive"]), value: 15000,
            currentWalletAddress: "ordinary-receive", selectedAddressType: .nativeSegwit
        )
        XCTAssertEqual(result, "server-receive")
        XCTAssertEqual(defaults.integer(forKey: key), 1200)
        XCTAssertNil(defaults.object(forKey: "addressSearch_lastUsedReceiveIndex_nativeSegwit"))
    }

    func testAccountZeroChangeKeepsPriorityAndExistingCacheKey() async throws {
        let search = AddressSearchCoordinator(
            defaults: defaults,
            listAccounts: { [OnchainWalletAccount(addressType: .nativeSegwit, accountIndex: 3)] },
            deriveAddresses: { account, keychain, start, _ in
                XCTAssertEqual(account.accountIndex, 0, "Account zero should resolve before companion derivation")
                return account.addressType == .nativeSegwit && keychain == .internal && start == 200 ? ["owned-change"] : []
            }
        )
        let result = try await search.runAddressSearch(
            details: details(["server-receive", "owned-change"]), value: 15000,
            currentWalletAddress: "", selectedAddressType: .nativeSegwit
        )
        XCTAssertEqual(result, "owned-change")
        XCTAssertEqual(defaults.integer(forKey: "addressSearch_lastUsedChangeIndex_nativeSegwit"), 200)
    }

    func testCurrentReceiveAddressDoesNotRequireAccountLookup() async throws {
        let search = AddressSearchCoordinator(
            defaults: defaults,
            listAccounts: { XCTFail("Current address should resolve without searching"); return [] },
            deriveAddresses: { _, _, _, _ in XCTFail("Current address should resolve without deriving"); return [] }
        )
        let result = try await search.runAddressSearch(
            details: details(["unrelated-change", "current"]), value: 15000,
            currentWalletAddress: "current", selectedAddressType: .nativeSegwit
        )
        XCTAssertEqual(result, "current")
    }

    func testUnregisteredAddressDoesNotMatchAndSearchStaysBounded() async throws {
        let search = AddressSearchCoordinator(
            defaults: defaults,
            listAccounts: { [] },
            deriveAddresses: { account, _, start, count in
                XCTAssertEqual(account.accountIndex, 0)
                XCTAssertLessThan(start, 1000)
                XCTAssertEqual(count, 200)
                return ["unrelated-owned-address"]
            }
        )
        let result = try await search.runAddressSearch(
            details: details(["unverified-first-output", "unregistered-account-address"]), value: 15000,
            currentWalletAddress: "", selectedAddressType: .nativeSegwit
        )
        XCTAssertNil(result)
    }

    func testDerivationFailureDoesNotSelectTransactionOutput() async throws {
        let search = AddressSearchCoordinator(
            defaults: defaults,
            listAccounts: { [OnchainWalletAccount(addressType: .nativeSegwit, accountIndex: 3)] },
            deriveAddresses: { _, _, _, _ in throw AppError(serviceError: .nodeNotSetup) }
        )
        let result = try await search.runAddressSearch(
            details: details(["unverified-first-output"]), value: 15000,
            currentWalletAddress: "", selectedAddressType: .nativeSegwit
        )
        XCTAssertNil(result)
    }

    private func details(_ addresses: [String]) -> BitkitCore.TransactionDetails {
        BitkitCore.TransactionDetails(
            walletId: WalletScope.default, txId: "tx", amountSats: 15000, inputs: [],
            outputs: addresses.enumerated().map { index, address in
                BitkitCore.TxOutput(
                    scriptpubkey: "", scriptpubkeyType: "p2wpkh", scriptpubkeyAddress: address,
                    value: index == addresses.count - 1 ? 15000 : 3000, n: UInt32(index)
                )
            }
        )
    }
}
