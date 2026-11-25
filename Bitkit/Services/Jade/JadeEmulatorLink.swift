import BitkitCore
import Darwin
import Foundation

/// Serial over TCP to the Jade QEMU emulator from bitkit-docker (`jade-emulator`), so the Jade flows
/// run in the simulator without a device. Debug and E2E builds only, behind `JADE_EMULATOR`; the
/// emulator shows up in scans as one more serial Jade at a `tcp:` path.
final class JadeEmulatorLink: @unchecked Sendable {
    static let shared = JadeEmulatorLink(address: Env.jadeEmulatorUrl, isEnabled: { Env.jadeEmulatorEnabled })

    static let pathPrefix = "tcp:"
    private static let deviceName = "Jade Emulator"
    private static let connectTimeoutMs: Int32 = 3000
    private static let readTimeoutMaxMs: UInt32 = 1000
    private static let readBufferBytes = 4096
    private static let logContext = "JadeEmulator"

    private let address: String
    private let isEnabled: () -> Bool
    private let lock = NSLock()
    private var sockets: [String: Int32] = [:]

    init(address: String, isEnabled: @escaping () -> Bool) {
        self.address = address
        self.isEnabled = isEnabled
    }

    var enabled: Bool {
        isEnabled()
    }

    private var path: String {
        Self.pathPrefix + address
    }

    func isEmulatorPath(_ path: String) -> Bool {
        isEnabled() && path.hasPrefix(Self.pathPrefix)
    }

    /// Lists the emulator only while its port answers, so a stopped container is not offered.
    func scanDevices() -> [JadeNativeDevice] {
        guard isEnabled() else { return [] }
        if socket(for: path) == nil {
            guard let probe = try? connect() else { return [] }
            close(probe)
        }
        return [JadeNativeDevice(path: path, transport: .serial, name: Self.deviceName, serialNumber: nil)]
    }

    func open(path: String) -> JadeTransportResult {
        closeDevice(path: path)
        do {
            let fd = try connect()
            lock.withLock { sockets[path] = fd }
            Logger.info("Opened Jade emulator '\(path)'", context: Self.logContext)
            return Self.success
        } catch {
            Logger.warn("Failed to open Jade emulator '\(path)': \(error)", context: Self.logContext)
            return JadeTransportResult(success: false, error: "\(error)", errorCode: .notConnected)
        }
    }

    @discardableResult
    func closeDevice(path: String) -> JadeTransportResult {
        if let fd = lock.withLock({ sockets.removeValue(forKey: path) }) {
            close(fd)
            Logger.info("Closed Jade emulator '\(path)'", context: Self.logContext)
        }
        return Self.success
    }

    func closeAll() {
        let paths = lock.withLock { Array(sockets.keys) }
        paths.forEach { closeDevice(path: $0) }
    }

    func write(path: String, data: Data) -> JadeTransportResult {
        guard let fd = socket(for: path) else {
            return JadeTransportResult(success: false, error: "Device not open: '\(path)'", errorCode: .notConnected)
        }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                send(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if written <= 0 {
                return JadeTransportResult(success: false, error: "Jade emulator write failed: errno \(errno)", errorCode: .disconnected)
            }
            offset += written
        }
        return Self.success
    }

    func read(path: String, timeoutMs: UInt32) -> JadeTransportReadResult {
        guard let fd = socket(for: path) else {
            return JadeTransportReadResult(success: false, data: Data(), error: "Device not open: '\(path)'", errorCode: .notConnected)
        }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, Int32(min(max(timeoutMs, 1), Self.readTimeoutMaxMs)))
        // Nothing received yet is the normal state while the device works or waits.
        guard ready > 0 else { return JadeTransportReadResult(success: true, data: Data(), error: "", errorCode: nil) }
        var buffer = [UInt8](repeating: 0, count: Self.readBufferBytes)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            return JadeTransportReadResult(success: false, data: Data(), error: "Jade emulator closed the connection", errorCode: .disconnected)
        }
        return JadeTransportReadResult(success: true, data: Data(buffer[0 ..< count]), error: "", errorCode: nil)
    }

    // MARK: - Helpers

    private static let success = JadeTransportResult(success: true, error: "", errorCode: nil)

    private func socket(for path: String) -> Int32? {
        lock.withLock { sockets[path] }
    }

    private func connect() throws -> Int32 {
        guard let separator = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: separator)...]) else {
            throw JadeEmulatorError.invalidAddress(address)
        }
        let host = String(address[..<separator])
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw JadeEmulatorError.invalidAddress(address) }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw JadeEmulatorError.connectFailed(errno) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        // Connect without blocking, so a stopped emulator fails within the timeout.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                let error = errno
                close(fd)
                throw JadeEmulatorError.connectFailed(error)
            }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            let ready = poll(&poller, 1, Self.connectTimeoutMs)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard ready > 0, socketError == 0 else {
                close(fd)
                throw JadeEmulatorError.connectFailed(ready > 0 ? socketError : ETIMEDOUT)
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }
}

enum JadeEmulatorError: Error, CustomStringConvertible {
    case invalidAddress(String)
    case connectFailed(Int32)

    var description: String {
        switch self {
        case let .invalidAddress(address):
            "Invalid Jade emulator address '\(address)'"
        case let .connectFailed(code):
            "Jade emulator connect failed: \(String(cString: strerror(code)))"
        }
    }
}
