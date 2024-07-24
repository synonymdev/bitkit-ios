//
//  LdkMigration.swift
//  BitkitTests
//
//  Created by Jason van den Berg on 2024/07/23.
//

import XCTest

final class LdkMigration: XCTestCase {
    
    override func setUpWithError() throws {
        try? FileManager.default.removeItem(at: Env.appStorageUrl) //Removes 'unit-test' directory
    }
    
    override func tearDownWithError() throws {
        dumpLdkLogs()
    }
    
    func testLdkToLdkNode() async throws {
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
                                
        try MigrationsService.shared.ldkToLdkNode(
            seed: try Data(contentsOf: seedFile),
            manager: try Data(contentsOf: managerFile),
            monitors: [
                try Data(contentsOf: channelFile)
            ]
        )

        try await LightningService.shared.setup(mnemonic: Env.testMnemonic, passphrase: nil)
        try await LightningService.shared.start()
        
        XCTAssertEqual(LightningService.shared.nodeId, "02cd08b7b375e4263849121f9f0ffb2732a0b88d0fb74487575ac539b374f45a55")
        
        let channels = LightningService.shared.channels
                XCTAssertEqual(channels?.count, 1)
        
        try await LightningService.shared.stop()
        
//        sleep(5)
        //TODO spin up LDK and query channel monitors
    }
    
    func dumpLdkLogs() {
        let dir = Env.ldkStorage
        let fileURL = dir.appendingPathComponent("ldk_node_latest.log")
        
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }
        let lines = text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        print("*****LDK-NODE LOG******")
        lines.suffix(20).forEach { line in
            print(line)
        }
        print("*****END LOG******")
    }
    
    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }
}
