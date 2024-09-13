//
//  LdkMigration.swift
//  BitkitTests
//
//  Created by Jason van den Berg on 2024/07/23.
//

import XCTest

final class LdkMigrationTests: XCTestCase {
    let walletIndex = 0
    
    override func setUpWithError() throws {}
    
    override func tearDownWithError() throws {
        dumpLdkLogs()
    }
    
    func testLdkToLdkNode() async throws {
        try Keychain.wipeEntireKeychain()
        try await LightningService.shared.wipeStorage(walletIndex: walletIndex)

        guard let seedFile = Bundle(for: type(of: self)).url(forResource: "seed", withExtension: "bin") else {
            XCTFail("Missing file: seed.bin")
            return
        }
        
        guard let managerFile = Bundle(for: type(of: self)).url(forResource: "channel_manager", withExtension: "bin") else {
            XCTFail("Missing file: channel_manager.bin")
            return
        }
        
        guard let channelFile = Bundle(for: type(of: self)).url(forResource: "adb1de43b448b04b3fdde638155929cd2163d2c53d36bb40b517d7acc44d1630", withExtension: "bin") else {
            XCTFail("Missing file: adb1de43b448b04b3fdde638155929cd2163d2c53d36bb40b517d7acc44d1630.bin")
            return
        }
        
        let testMnemonic = "pool curve feature leader elite dilemma exile toast smile couch crane public"
        
        try Keychain.saveString(key: .bip39Mnemonic(index: 0), str: testMnemonic)
        
        try MigrationsService.shared.ldkToLdkNode(
            walletIndex: 0,
            seed: Data(contentsOf: seedFile),
            manager: Data(contentsOf: managerFile),
            monitors: [
                Data(contentsOf: channelFile)
            ]
        )
        
        // TODO: restore first from words
        try await LightningService.shared.setup(walletIndex: walletIndex)
        try await LightningService.shared.start()
        
        XCTAssertEqual(LightningService.shared.nodeId, "02cd08b7b375e4263849121f9f0ffb2732a0b88d0fb74487575ac539b374f45a55")

        let channels = LightningService.shared.channels
        XCTAssertEqual(channels?.count, 1)

        try await LightningService.shared.stop()
    }
    
    func dumpLdkLogs() {
        let dir = Env.ldkStorage(walletIndex: walletIndex)
        let fileURL = dir.appendingPathComponent("ldk_node_latest.log")
        
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        print("*****LDK-NODE LOG******")
        for line in lines.suffix(20) {
            print(line)
        }
        print("*****END LOG******")
    }
}
