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
    }
    
    func testLdkToLdkNode() async throws {
        try MigrationsService.shared.ldkToLdkNode()
        
        sleep(2)
        
        try await LightningService.shared.setup(mnemonic: Env.testMnemonic, passphrase: nil)
        try await LightningService.shared.start()
        
        XCTAssertEqual(LightningService.shared.nodeId, "02cd08b7b375e4263849121f9f0ffb2732a0b88d0fb74487575ac539b374f45a55")
        
        sleep(10)
        let channels = LightningService.shared.channels
//        XCTAssertEqual(channels?.count, 1)
        
        try await LightningService.shared.stop()
        
        sleep(5)
        //TODO spin up LDK and query channel monitors
    }
    
    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }
}
