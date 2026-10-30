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
        let calls = AddressSearchCallLog()
        let search = AddressSearchCoordinator(
            defaults: defaults,
            listAccounts: {
                await calls.record("list")
                return [
                    OnchainWalletAccount(addressType: .nativeSegwit, accountIndex: 3),
                    OnchainWalletAccount(addressType: .taproot, accountIndex: 2),
                    OnchainWalletAccount(addressType: .nativeSegwit, accountIndex: 0),
                    OnchainWalletAccount(addressType: .legacy, accountIndex: 2),
                ]
            },
            deriveAddresses: { account, keychain, start, count in
                XCTAssertTrue(account.accountIndex > 0 || account.addressType == .nativeSegwit)
                if start == 0 {
                    await calls.record("\(account.addressType.stringValue):\(account.accountIndex):\(keychain)")
                }
                XCTAssertEqual(count, 200)
                if account.accountIndex == 3, keychain == .external, start == 1200 {
                    return [LightningService.AddressDerivationInfo(address: "server-receive", index: 1200)]
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
        let recorded = await calls.events
        XCTAssertEqual(recorded, [
            "list", "nativeSegwit:0:external", "nativeSegwit:0:internal",
            "legacy:2:external", "taproot:2:external", "nativeSegwit:3:external",
        ])
    }

    func testAccountZeroChangeKeepsPriorityAndExistingCacheKey() async throws {
        let calls = AddressSearchCallLog()
        let search = AddressSearchCoordinator(
            defaults: defaults,
            listAccounts: {
                [
                    OnchainWalletAccount(addressType: .legacy, accountIndex: 0),
                    OnchainWalletAccount(addressType: .nativeSegwit, accountIndex: 3),
                    OnchainWalletAccount(addressType: .nativeSegwit, accountIndex: 0),
                ]
            },
            deriveAddresses: { account, keychain, start, _ in
                XCTAssertEqual(account.accountIndex, 0, "Account zero should resolve before companion derivation")
                if start == 0 {
                    await calls.record("\(account.addressType.stringValue):\(account.accountIndex):\(keychain)")
                }
                if account.accountIndex == 3 {
                    return [LightningService.AddressDerivationInfo(address: "server-receive", index: 0)]
                }
                return account.addressType == .nativeSegwit && keychain == .internal && start == 200
                    ? [LightningService.AddressDerivationInfo(address: "owned-change", index: 203)] : []
            }
        )
        let result = try await search.runAddressSearch(
            details: details(["server-receive", "owned-change"]), value: 15000,
            currentWalletAddress: "", selectedAddressType: .nativeSegwit
        )
        XCTAssertEqual(result, "owned-change")
        XCTAssertEqual(defaults.integer(forKey: "addressSearch_lastUsedChangeIndex_nativeSegwit"), 203)
        let recorded = await calls.events
        XCTAssertEqual(recorded, ["nativeSegwit:0:external", "legacy:0:external", "nativeSegwit:0:internal"])
        XCTAssertNil(defaults.object(forKey: "addressSearch_lastUsedReceiveIndex_nativeSegwit_account3"))
    }

    func testMatchedCompanionReceiveIndexExtendsPersistedWindowByOneThousand() async throws {
        let key = "addressSearch_lastUsedReceiveIndex_nativeSegwit_account3"
        for matchIndex in [999, 1999] {
            let search = AddressSearchCoordinator(
                defaults: defaults,
                listAccounts: { [OnchainWalletAccount(addressType: .nativeSegwit, accountIndex: 3)] },
                deriveAddresses: { account, keychain, start, count in
                    guard account.accountIndex == 3, account.addressType == .nativeSegwit, keychain == .external else { return [] }
                    XCTAssertLessThanOrEqual(start + count, UInt32(matchIndex + 1))
                    return (start ..< start + count).map { LightningService.AddressDerivationInfo(address: "owned-\($0)", index: $0) }
                }
            )
            let result = try await search.runAddressSearch(
                details: details(["owned-\(matchIndex - 1)", "owned-\(matchIndex)"]), value: 15000,
                currentWalletAddress: "", selectedAddressType: .nativeSegwit
            )
            XCTAssertEqual(result, "owned-\(matchIndex)")
            XCTAssertEqual(defaults.integer(forKey: key), matchIndex)
        }
        XCTAssertNil(defaults.object(forKey: "addressSearch_lastUsedReceiveIndex_nativeSegwit"))
    }

    func testSearchIncludesOneThousandAheadAtBatchBoundaryButNotBeyond() async throws {
        let key = "addressSearch_lastUsedChangeIndex_nativeSegwit"
        for matchIndex in [2000, 2001] {
            defaults.set(1000, forKey: key)
            let search = AddressSearchCoordinator(
                defaults: defaults,
                listAccounts: {
                    LDKNode.AddressType.allAddressTypes.map { OnchainWalletAccount(addressType: $0, accountIndex: 0) }
                },
                deriveAddresses: { account, keychain, start, count in
                    guard account.accountIndex == 0, account.addressType == .nativeSegwit, keychain == .internal else { return [] }
                    XCTAssertLessThanOrEqual(start + count, 2001)
                    return (start ..< start + count).map { LightningService.AddressDerivationInfo(address: "owned-\($0)", index: $0) }
                }
            )
            let result = try await search.runAddressSearch(
                details: details(["owned-\(matchIndex)"]), value: 15000,
                currentWalletAddress: "", selectedAddressType: .nativeSegwit
            )
            XCTAssertEqual(result, matchIndex == 2000 ? "owned-2000" : nil)
            XCTAssertEqual(defaults.integer(forKey: key), matchIndex == 2000 ? 2000 : 1000)
        }
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
            listAccounts: {
                LDKNode.AddressType.allAddressTypes.map { OnchainWalletAccount(addressType: $0, accountIndex: 0) }
            },
            deriveAddresses: { account, _, start, count in
                XCTAssertEqual(account.accountIndex, 0)
                XCTAssertLessThan(start, 1000)
                XCTAssertEqual(count, 200)
                return [LightningService.AddressDerivationInfo(address: "unrelated-owned-address", index: start)]
            }
        )
        let result = try await search.runAddressSearch(
            details: details(["unverified-first-output", "unregistered-account-address"]), value: 15000,
            currentWalletAddress: "", selectedAddressType: .nativeSegwit
        )
        XCTAssertNil(result)
    }

    func testDerivationFailureDoesNotSelectTransactionOutput() async throws {
        for error in [AppError(serviceError: .nodeNotSetup), CancellationError()] as [Error] {
            let search = AddressSearchCoordinator(
                defaults: defaults,
                listAccounts: { [OnchainWalletAccount(addressType: .nativeSegwit, accountIndex: 3)] },
                deriveAddresses: { _, _, _, _ in throw error }
            )
            let result = try await search.runAddressSearch(
                details: details(["unverified-first-output"]), value: 15000,
                currentWalletAddress: "", selectedAddressType: .nativeSegwit
            )
            XCTAssertNil(result)
            XCTAssertNil(defaults.object(forKey: "addressSearch_lastUsedReceiveIndex_nativeSegwit_account3"))
            XCTAssertNil(defaults.object(forKey: "addressSearch_lastUsedChangeIndex_nativeSegwit_account3"))
        }
    }

    func testEmptyAccountListIsReadAgainForTheNextSearch() async throws {
        let calls = AddressSearchCallLog()
        let search = AddressSearchCoordinator(
            defaults: defaults,
            listAccounts: {
                let count = await calls.record("list")
                return count == 1 ? [] : [OnchainWalletAccount(addressType: .taproot, accountIndex: 0)]
            },
            deriveAddresses: { account, keychain, start, _ in
                await calls.record("derive")
                XCTAssertEqual(account.addressType, .taproot)
                XCTAssertEqual(account.accountIndex, 0)
                XCTAssertEqual(keychain, .external)
                XCTAssertEqual(start, 0)
                return [LightningService.AddressDerivationInfo(address: "newly-loaded", index: 0)]
            }
        )
        let first = try await search.runAddressSearch(
            details: details(["newly-loaded"]), value: 15000,
            currentWalletAddress: "", selectedAddressType: .nativeSegwit
        )
        XCTAssertNil(first)
        XCTAssertNil(defaults.object(forKey: "addressSearch_lastUsedReceiveIndex_taproot"))
        let firstCalls = await calls.events
        XCTAssertEqual(firstCalls, ["list"])

        let second = try await search.runAddressSearch(
            details: details(["newly-loaded"]), value: 15000,
            currentWalletAddress: "", selectedAddressType: .nativeSegwit
        )
        XCTAssertEqual(second, "newly-loaded")
        XCTAssertEqual(defaults.object(forKey: "addressSearch_lastUsedReceiveIndex_taproot") as? Int, 0)
        let allCalls = await calls.events
        XCTAssertEqual(allCalls, ["list", "list", "derive"])
    }

    func testAccountListingFailureKeepsPrimaryFallback() async throws {
        for error in [AppError(serviceError: .nodeNotSetup), CancellationError()] as [Error] {
            let calls = AddressSearchCallLog()
            let search = AddressSearchCoordinator(
                defaults: defaults,
                listAccounts: { throw error },
                deriveAddresses: { account, keychain, start, _ in
                    XCTAssertEqual(account.accountIndex, 0)
                    if start == 0 {
                        await calls.record("\(account.addressType.stringValue):\(keychain)")
                    }
                    return account.addressType == .nativeSegwit && keychain == .internal && start == 0
                        ? [LightningService.AddressDerivationInfo(address: "owned-change", index: 7)] : []
                }
            )
            let result = try await search.runAddressSearch(
                details: details(["owned-change"]), value: 15000,
                currentWalletAddress: "", selectedAddressType: .taproot
            )
            XCTAssertEqual(result, "owned-change")
            XCTAssertEqual(defaults.integer(forKey: "addressSearch_lastUsedChangeIndex_nativeSegwit"), 7)
            let recorded = await calls.events
            XCTAssertEqual(recorded, [
                "taproot:external", "legacy:external", "nestedSegwit:external", "nativeSegwit:external",
                "taproot:internal", "legacy:internal", "nestedSegwit:internal", "nativeSegwit:internal",
            ])
        }
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

private actor AddressSearchCallLog {
    private(set) var events: [String] = []

    @discardableResult
    func record(_ event: String) -> Int {
        events.append(event)
        return events.count
    }
}
