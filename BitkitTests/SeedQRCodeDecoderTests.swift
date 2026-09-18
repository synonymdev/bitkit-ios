@testable import Bitkit
import Foundation
import XCTest

final class SeedQRCodeDecoderTests: XCTestCase {
    func testDecodesStandardSeedQR() throws {
        let payload = QRCodePayload(
            string: "073318950739065415961602009907670428187212261116",
            data: nil
        )

        let mnemonic = try SeedQRCodeDecoder.decode(payload)

        XCTAssertEqual(mnemonic, "forum undo fragile fade shy sign arrest garment culture tube off merit")
    }

    func testDecodesCompactSeedQR() throws {
        let payload = QRCodePayload(
            string: nil,
            data: Data([0x5B, 0xBD, 0x9D, 0x71, 0xA8, 0xEC, 0x79, 0x90, 0x83, 0x1A, 0xFF, 0x35, 0x9D, 0x42, 0x65, 0x45])
        )

        let mnemonic = try SeedQRCodeDecoder.decode(payload)

        XCTAssertEqual(mnemonic, "forum undo fragile fade shy sign arrest garment culture tube off merit")
    }

    func testDecodesCompactSeedQRVisionPayload() throws {
        let payload = QRCodePayload(
            string: nil,
            data: Data([0x41, 0x05, 0xBB, 0xD9, 0xD7, 0x1A, 0x8E, 0xC7, 0x99, 0x08, 0x31, 0xAF, 0xF3, 0x59, 0xD4, 0x26, 0x54, 0x50, 0xEC])
        )

        let mnemonic = try SeedQRCodeDecoder.decode(payload)

        XCTAssertEqual(mnemonic, "forum undo fragile fade shy sign arrest garment culture tube off merit")
    }

    func testDecodesCompactSeedQRContainingNullBytes() throws {
        let payload = QRCodePayload(
            string: nil,
            data: Data(repeating: 0, count: 16)
        )

        let mnemonic = try SeedQRCodeDecoder.decode(payload)

        XCTAssertEqual(mnemonic, "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
    }

    func testDecodesStandardSeedQRFromRawData() throws {
        let standardPayload = "008607501025021714880023171503630517020917211425"
        let payload = QRCodePayload(string: nil, data: Data(standardPayload.utf8))

        let mnemonic = try SeedQRCodeDecoder.decode(payload)

        XCTAssertEqual(mnemonic, "approve fruit lens brass ring actual stool coin doll boss strong rate")
    }

    func testRejectsStandardSeedQRWithInvalidChecksum() {
        let payload = QRCodePayload(
            string: String(repeating: "0000", count: 12),
            data: nil
        )

        XCTAssertThrowsError(try SeedQRCodeDecoder.decode(payload))
    }

    func testRejectsOutOfRangeWordIndex() {
        let payload = QRCodePayload(
            string: "2048" + String(repeating: "0000", count: 11),
            data: nil
        )

        XCTAssertThrowsError(try SeedQRCodeDecoder.decode(payload))
    }

    func testRejectsUnsupportedPayloadLength() {
        let payload = QRCodePayload(string: nil, data: Data(repeating: 0, count: 15))

        XCTAssertThrowsError(try SeedQRCodeDecoder.decode(payload))
    }
}
