@testable import Bitkit
import BitkitCore
import Network
import os
import XCTest

final class ClipboardPromptValidatorTests: XCTestCase {
    func testLightningAddressCandidatesDoNotInvokeNetworkDecoder() async {
        for uri in [
            "alice@corp.example",
            "lightning:alice@corp.example",
            "LIGHTNING:alice@corp.example",
            "lnurlp:alice@corp.example",
            "bitkit://alice@corp.example",
            "bitkit://lightning:alice@corp.example",
            "bitkit://lightning:bitkit://alice@corp.example",
        ] {
            let supported = await ClipboardPromptValidator.isSupportedURI(uri, ownPublicKey: nil, contacts: []) { _ in
                XCTFail("Must not decode a network-resolved clipboard candidate before confirmation: '\(uri)'")
                return false
            }
            XCTAssertTrue(supported, uri)
        }
    }

    func testWrappedLnurlCandidatesDoNotInvokeNetworkDecoder() async {
        let lnurl = ClipboardLnurlEncoder.encode("http://127.0.0.1/lnurlp")
        for uri in wrappedLnurls(lnurl) {
            let supported = await ClipboardPromptValidator.isSupportedURI(uri, ownPublicKey: nil, contacts: []) { _ in
                XCTFail("Must not decode a network-resolved clipboard candidate before confirmation: '\(uri)'")
                return false
            }
            XCTAssertTrue(supported, uri)
        }
    }

    func testNativeInspectionDoesNotConnectToEncodedLnurlEndpoints() async throws {
        let probe = try ClipboardConnectionProbe()
        defer { probe.stop() }
        let ready = expectation(description: "loopback listener ready")
        probe.start(ready: ready)
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(probe.port)
        let lnurl = ClipboardLnurlEncoder.encode("http://127.0.0.1:\(port)/lnurlp")

        for uri in wrappedLnurls(lnurl) {
            let supported = await ClipboardPromptValidator.isSupportedURI(uri, ownPublicKey: nil, contacts: [])
            XCTAssertTrue(supported, uri)
        }
        XCTAssertEqual(probe.connections, 0, "Automatic inspection must not contact clipboard-derived endpoints")
    }

    func testExplicitNativeDecodingStillConnectsToEncodedLnurlEndpoints() async throws {
        let probe = try ClipboardConnectionProbe()
        defer { probe.stop() }
        let ready = expectation(description: "loopback listener ready")
        probe.start(ready: ready)
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(probe.port)
        let lnurl = ClipboardLnurlEncoder.encode("http://127.0.0.1:\(port)/lnurlp")

        for uri in [lnurl, "https://example.com/pay?lightning=\(lnurl)", "bitkit://\(lnurl)"] {
            // The probe returns 404; a decoding failure is expected, but the request proves the fixture is valid.
            let decoded = try? await decode(invoice: uri)
            XCTAssertNil(decoded)
        }
        XCTAssertEqual(probe.connections, 3)
    }

    func testLocalPaymentFormatsRemainSupported() async {
        let address = "mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn"
        for uri in [address, "bitcoin:\(address)?amount=0.001", "LIGHTNING:\(address)", "bitkit://\(address)", "bitkit://gift-test-1000"] {
            let supported = await ClipboardPromptValidator.isSupportedURI(uri, ownPublicKey: nil, contacts: [])
            XCTAssertTrue(supported, uri)
        }
    }

    func testBolt11InvoiceRemainsLocallyValidated() async {
        let invoice =
            "lnbcrt200n1p5hn4c8dqqnp4qwrgh4a03djj2sl34465uwnxhva0gtpjm4u8kvzgc5jergrkm9syypp55lwcgfpkdwuknmekjgted72n0ddl5qtaha7knk7c9n7yrjr4auassp5jgqw0a9w33e2ta4j7gyjrvsvu0lv844w895305nd8spnknq3f2hq9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcsqqqqlgqqqqqqgq2qd2gk64eg2kfxtdaryrlh98hvu97jdaxz2ma7aeyuy2uy9vkn9x5qft47p9taju297xnrehva20xcfml7wacuv737xv3xjjzyrtplcxqpfpu9dt"
        let supported = await ClipboardPromptValidator.isSupportedURI(invoice, ownPublicKey: nil, contacts: [])
        XCTAssertTrue(supported)
    }

    func testOrdinaryUnsupportedContentRemainsRejected() async {
        for uri in ["", "ordinary clipboard text", "https://example.com", "alice+invalid@corp.example", "Alice@corp.example", "lnurl1invalid"] {
            let supported = await ClipboardPromptValidator.isSupportedURI(uri, ownPublicKey: nil, contacts: [])
            XCTAssertFalse(supported, uri)
        }
    }

    func testDuplicateBip21IsRejectedBeforeCandidateRecognition() async {
        let supported = await ClipboardPromptValidator.isSupportedURI(
            "bitcoin:bitcoin:invalid?lightning=lnurl1qqqqqq", ownPublicKey: nil, contacts: []
        ) { _ in
            XCTFail("Duplicated BIP21 must be rejected before decoding")
            return true
        }
        XCTAssertFalse(supported)
    }

    func testNonNetworkDecodeKeepsOriginalNormalizedPayload() async {
        let supported = await ClipboardPromptValidator.isSupportedURI("  LIGHTNING:lnbc-invalid  ", ownPublicKey: nil, contacts: []) {
            XCTAssertEqual($0, "lnbc-invalid")
            return false
        }
        XCTAssertFalse(supported)
    }

    @MainActor
    func testExistingSetupAndContactCandidatesDoNotInvokeDecoder() async {
        snapshotAppDefaults(PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        let key = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        for uri in [
            key,
            "https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123",
        ] {
            let supported = await ClipboardPromptValidator.isSupportedURI(uri, ownPublicKey: nil, contacts: []) { _ in
                XCTFail("Existing locally parsed candidates must not invoke the decoder")
                return false
            }
            XCTAssertTrue(supported, uri)
        }
    }

    private func wrappedLnurls(_ lnurl: String) -> [String] {
        [
            lnurl,
            lnurl.uppercased(),
            "  \(lnurl)  ",
            "lightning:\(lnurl)",
            "LNURL:\(lnurl.uppercased())",
            "lnurlp:\(lnurl)",
            "lnurlw:\(lnurl)",
            "lnurlc:\(lnurl)",
            "https://example.com/pay?lightning=\(lnurl)",
            "https://example.com/pay?amount=1&lightning=\(lnurl)",
            "HTTPS://EXAMPLE.COM/PAY?LIGHTNING=\(lnurl.uppercased())",
            "bitkit://\(lnurl)",
            "bitkit://lightning:\(lnurl)",
            "bitkit://bitkit://\(lnurl)",
            "bitkit://https://example.com/pay?lightning=\(lnurl)",
        ]
    }
}

private final class ClipboardConnectionProbe {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ClipboardConnectionProbe")
    private let hits = OSAllocatedUnfairLock(initialState: 0)

    var port: UInt16? {
        listener.port?.rawValue
    }

    var connections: Int {
        hits.withLock { $0 }
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start(ready: XCTestExpectation) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.fulfill()
            case let .failed(error):
                XCTFail("Loopback listener failed: \(error)")
                ready.fulfill()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            hits.withLock { $0 += 1 }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }
}

private enum ClipboardLnurlEncoder {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let generators: [UInt32] = [0x3B6A_57B2, 0x2650_8E6D, 0x1EA1_19FA, 0x3D42_33DD, 0x2A14_62B3]

    static func encode(_ url: String) -> String {
        var accumulator = 0
        var bits = 0
        var values: [UInt8] = []
        for byte in url.utf8 {
            accumulator = ((accumulator << 8) | Int(byte)) & 0xFFF
            bits += 8
            while bits >= 5 {
                bits -= 5
                values.append(UInt8((accumulator >> bits) & 31))
            }
        }
        if bits > 0 {
            values.append(UInt8((accumulator << (5 - bits)) & 31))
        }
        let hrp = Array("lnurl".utf8)
        let expanded = hrp.map { $0 >> 5 } + [0] + hrp.map { $0 & 31 }
        var checksum: UInt32 = 1
        for value in expanded + values + Array(repeating: 0, count: 6) {
            let top = checksum >> 25
            checksum = ((checksum & 0x1FFFFFF) << 5) ^ UInt32(value)
            for index in 0 ..< 5 where (top >> index) & 1 != 0 {
                checksum ^= generators[index]
            }
        }
        checksum ^= 1
        let checkValues = (0 ..< 6).map { UInt8((checksum >> (5 * (5 - $0))) & 31) }
        return "lnurl1" + (values + checkValues).map { String(charset[Int($0)]) }.joined()
    }
}
