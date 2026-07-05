import BitkitCore
import Foundation

/// Dev/E2E-only transport for talking to the Trezor Bridge exposed by bitkit-docker.
final class TrezorBridgeTransport {
    static let shared = TrezorBridgeTransport()

    private static let pathPrefix = "bridge:"
    private static let deviceName = "Trezor Bridge Emulator"
    private static let vendorId = UInt16(0x1209)
    private static let productId = UInt16(0x53C1)
    private static let headerSize = 6
    private static let connectTimeout: TimeInterval = 5
    private static let readTimeout: TimeInterval = 30
    /// Longer read timeout for the on-device signing call, which blocks while the user confirms on
    /// the Trezor. Without it the standard 30s timeout fires before confirmation completes.
    private static let signTxReadTimeout: TimeInterval = 120
    /// Trezor protobuf `MessageType_SignTx`. The only call that waits for on-device signing.
    private static let signTxMessageType: UInt16 = 15

    private let decoder = JSONDecoder()
    private let sessionLock = NSLock()
    private var openSessions: [String: String] = [:]
    private var enumeratedSessions: [String: String] = [:]

    private init() {}

    var isEnabled: Bool {
        Env.trezorBridgeEnabled
    }

    func isBridgeDevice(path: String) -> Bool {
        isEnabled && path.hasPrefix(Self.pathPrefix)
    }

    func enumerateDevices() -> [NativeDeviceInfo] {
        guard isEnabled else { return [] }

        do {
            let response = try post(path: "/enumerate")
            let bridgeDevices = try decoder.decode([BridgeDevice].self, from: Data(response.utf8))

            let devices = bridgeDevices.map { device in
                let bridgePath = Self.toBridgePath(device.path)
                sessionLock.lock()
                if let session = device.session {
                    enumeratedSessions[bridgePath] = session
                } else {
                    enumeratedSessions.removeValue(forKey: bridgePath)
                }
                sessionLock.unlock()

                return NativeDeviceInfo(
                    path: bridgePath,
                    transportType: "usb",
                    name: Self.deviceName,
                    vendorId: Self.vendorId,
                    productId: Self.productId
                )
            }

            debugLog("enumerateDevices: \(devices.count) Bridge device(s)")
            return devices
        } catch {
            debugLog("enumerateDevices FAILED: \(error.localizedDescription)")
            return []
        }
    }

    func openDevice(path: String) -> TrezorTransportWriteResult {
        let rawPath = Self.rawBridgePath(path)

        sessionLock.lock()
        let previousSession = openSessions.removeValue(forKey: path) ?? enumeratedSessions[path] ?? "null"
        sessionLock.unlock()

        do {
            let response = try post(path: "/acquire/\(Self.encode(rawPath))/\(Self.encode(previousSession))")
            let bridgeSession = try decoder.decode(BridgeSession.self, from: Data(response.utf8))

            sessionLock.lock()
            openSessions[path] = bridgeSession.session
            sessionLock.unlock()

            debugLog("openDevice: \(path)")
            return TrezorTransportWriteResult(success: true, error: "", errorCode: nil)
        } catch {
            debugLog("openDevice FAILED: \(error.localizedDescription)")
            return TrezorTransportWriteResult(success: false, error: error.localizedDescription, errorCode: nil)
        }
    }

    func closeDevice(path: String) -> TrezorTransportWriteResult {
        sessionLock.lock()
        let session = openSessions.removeValue(forKey: path)
        sessionLock.unlock()

        guard let session else {
            return TrezorTransportWriteResult(success: true, error: "", errorCode: nil)
        }

        do {
            _ = try post(path: "/release/\(Self.encode(session))")
            debugLog("closeDevice: \(path)")
            return TrezorTransportWriteResult(success: true, error: "", errorCode: nil)
        } catch {
            debugLog("closeDevice FAILED: \(error.localizedDescription)")
            return TrezorTransportWriteResult(success: false, error: error.localizedDescription, errorCode: nil)
        }
    }

    func readChunk(path: String) -> TrezorTransportReadResult {
        TrezorTransportReadResult(success: false, data: Data(), error: "Trezor Bridge uses callMessage for \(path)", errorCode: nil)
    }

    func writeChunk(path: String, data: Data) -> TrezorTransportWriteResult {
        TrezorTransportWriteResult(
            success: false,
            error: "Trezor Bridge uses callMessage for \(path) and ignored \(data.count) bytes",
            errorCode: nil
        )
    }

    func callMessage(path: String, messageType: UInt16, data: Data) -> TrezorCallMessageResult {
        sessionLock.lock()
        let session = openSessions[path]
        sessionLock.unlock()

        guard let session else {
            return TrezorCallMessageResult(
                success: false,
                messageType: 0,
                data: Data(),
                error: "Trezor Bridge device not open: \(path)",
                errorCode: nil
            )
        }

        do {
            let request = Self.encodeFrame(messageType: messageType, data: data)
            // Signing blocks on device confirmation, so it needs a longer read timeout than the
            // standard management calls.
            let readTimeout = messageType == Self.signTxMessageType ? Self.signTxReadTimeout : Self.readTimeout
            let response = try post(path: "/call/\(Self.encode(session))", body: request, readTimeout: readTimeout)
            return try Self.decodeFrame(response)
        } catch {
            debugLog("callMessage FAILED: \(error.localizedDescription)")
            return TrezorCallMessageResult(success: false, messageType: 0, data: Data(), error: error.localizedDescription, errorCode: nil)
        }
    }

    private func post(path: String, body: String? = nil, readTimeout: TimeInterval? = nil) throws -> String {
        guard let url = URL(string: "\(Env.trezorBridgeUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(path)") else {
            throw TrezorBridgeTransportError.invalidUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = body == nil ? Self.connectTimeout : (readTimeout ?? Self.readTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error>?

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure(TrezorBridgeTransportError.invalidResponse)
                return
            }
            result = .success((data ?? Data(), httpResponse))
        }.resume()

        semaphore.wait()

        let (data, response) = try result?.get() ?? (Data(), HTTPURLResponse())
        let responseText = String(data: data, encoding: .utf8) ?? ""
        guard 200 ..< 300 ~= response.statusCode else {
            throw TrezorBridgeTransportError.httpError(statusCode: response.statusCode, body: responseText)
        }
        return responseText
    }

    private static func encodeFrame(messageType: UInt16, data: Data) -> String {
        var frame = Data()
        frame.append(UInt8((messageType >> 8) & 0xFF))
        frame.append(UInt8(messageType & 0xFF))

        let length = UInt32(data.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(data)

        return frame.map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeFrame(_ hex: String) throws -> TrezorCallMessageResult {
        let bytes = try Data(hexEncoded: hex.trimmingCharacters(in: .whitespacesAndNewlines))
        guard bytes.count >= headerSize else {
            throw TrezorBridgeTransportError.shortResponse
        }

        let messageType = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        let length = (UInt32(bytes[2]) << 24) | (UInt32(bytes[3]) << 16) | (UInt32(bytes[4]) << 8) | UInt32(bytes[5])
        guard bytes.count >= headerSize + Int(length) else {
            throw TrezorBridgeTransportError.invalidPayloadLength
        }

        let payload = bytes.subdata(in: headerSize ..< headerSize + Int(length))
        return TrezorCallMessageResult(success: true, messageType: messageType, data: payload, error: "", errorCode: nil)
    }

    private static func toBridgePath(_ path: String) -> String {
        "\(pathPrefix)\(path)"
    }

    private static func rawBridgePath(_ path: String) -> String {
        String(path.dropFirst(pathPrefix.count))
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func debugLog(_ message: String) {
        Logger.debug(message, context: "TrezorBridgeTransport")
        TrezorDebugLog.shared.log("[Bridge] \(message)")
    }
}

private struct BridgeDevice: Decodable {
    let path: String
    let session: String?
}

private struct BridgeSession: Decodable {
    let session: String
}

private enum TrezorBridgeTransportError: LocalizedError {
    case invalidUrl
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case invalidHex
    case shortResponse
    case invalidPayloadLength

    var errorDescription: String? {
        switch self {
        case .invalidUrl:
            return "Invalid Trezor Bridge URL"
        case .invalidResponse:
            return "Invalid Trezor Bridge response"
        case let .httpError(statusCode, body):
            return "Bridge request failed with HTTP \(statusCode): \(body)"
        case .invalidHex:
            return "Bridge returned invalid hex"
        case .shortResponse:
            return "Bridge response is shorter than the message header"
        case .invalidPayloadLength:
            return "Bridge response payload length exceeds available data"
        }
    }
}

private extension Data {
    init(hexEncoded hex: String) throws {
        guard hex.count.isMultiple(of: 2) else {
            throw TrezorBridgeTransportError.invalidHex
        }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< nextIndex], radix: 16) else {
                throw TrezorBridgeTransportError.invalidHex
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
