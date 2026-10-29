@testable import Bitkit
import LDKNode
import XCTest

final class PrimaryNodeTests: XCTestCase {
    private let nodeId = "024a6cc632544189896cca8e06e375bdb1d1f34a71a4c25d09a39cf0ed920a299c"

    func testParsesNodeUriAndNormalizesIt() throws {
        let primary = try PrimaryNode.parse("lightning:\(nodeId.uppercased())@Bore.pub:39101")

        XCTAssertEqual(primary, PrimaryNode(nodeId: nodeId, address: "bore.pub:39101"))
        XCTAssertEqual(primary.uri, "\(nodeId)@bore.pub:39101")
    }

    func testParsesBarePublicKeyWithoutAddress() throws {
        XCTAssertEqual(try PrimaryNode.parse(nodeId), PrimaryNode(nodeId: nodeId, address: nil))
    }

    func testRejectsInvalidKeysAndAddresses() {
        XCTAssertThrowsError(try PrimaryNode.parse("04" + String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try PrimaryNode.parse("\(nodeId)@host:0"))
        XCTAssertThrowsError(try PrimaryNode.parse("\(nodeId)@host:9735/path"))
        XCTAssertThrowsError(try PrimaryNode.parse("\(nodeId) @host:9735"))
        XCTAssertNil(PrimaryNode.parseOrNil("not a node"))
    }

    func testFundingPlanMovesConfirmedSavingsMinusMiningFee() throws {
        let plan = try XCTUnwrap(PrimaryFundingPlan.plan(spendableSats: 50000, inputs: 1, feeRate: 2, hasChannel: true))

        XCTAssertEqual(plan.feeSats, 1200)
        XCTAssertEqual(plan.amountSats, 48800)
        XCTAssertFalse(plan.opensChannel)
        XCTAssertTrue(plan.isAutomatic)
    }

    func testAutomaticFundingWaitsBelowMinimumOrAboveFeeLimit() throws {
        let small = try XCTUnwrap(PrimaryFundingPlan.plan(spendableSats: 24999, inputs: 1, feeRate: 1, hasChannel: true))
        let expensive = try XCTUnwrap(PrimaryFundingPlan.plan(spendableSats: 30000, inputs: 1, feeRate: 3, hasChannel: false))

        XCTAssertFalse(small.isAutomatic)
        XCTAssertFalse(expensive.isAutomatic)
        XCTAssertTrue(expensive.opensChannel)
        XCTAssertNil(PrimaryFundingPlan.plan(spendableSats: 500, inputs: 1, feeRate: 1, hasChannel: true))
    }

    func testLiquidityErrorsMapToWhatTheUserIsTold() {
        func map(_ error: NodeError) -> PrimaryReceiveError? {
            PrimaryNodeService.mapError(error) as? PrimaryReceiveError
        }

        XCTAssertEqual(map(.LiquiditySourceInsufficientFunds(message: "")), .insufficientFunds)
        XCTAssertEqual(map(.LiquidityRequestRejected(message: "")), .rejected)
        XCTAssertEqual(map(.LiquidityRequestTimedOut(message: "")), .timedOut)
        XCTAssertEqual(map(.LiquidityReceiveAmountTooSmall(message: "")), .amountTooSmall)
        XCTAssertEqual(map(.ConnectionFailed(message: "")), .offline)
    }
}
