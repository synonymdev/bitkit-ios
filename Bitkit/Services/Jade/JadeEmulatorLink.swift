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
    private var sockets: [String: EmulatorSocket] = [:]

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
        if lock.withLock({ sockets[path] }) == nil {
            do {
                try close(connect())
            } catch {
                if case JadeEmulatorError.invalidAddress = error {
                    Logger.warn("Failed to scan for the Jade emulator: \(error)", context: Self.logContext)
                }
                return []
            }
        }
        return [JadeNativeDevice(path: path, transport: .serial, name: Self.deviceName, serialNumber: nil)]
    }

    func open(path: String) -> JadeTransportResult {
        closeDevice(path: path)
        do {
            let fd = try connect()
            lock.withLock { sockets[path] = EmulatorSocket(fd: fd) }
            Logger.info("Opened Jade emulator '\(path)'", context: Self.logContext)
            return Self.success
        } catch {
            Logger.warn("Failed to open Jade emulator '\(path)': \(error)", context: Self.logContext)
            return JadeTransportResult(success: false, error: "\(error)", errorCode: .notConnected)
        }
    }

    @discardableResult
    func closeDevice(path: String) -> JadeTransportResult {
        if let socket = lock.withLock({ sockets.removeValue(forKey: path) }) {
            retire(socket)
            Logger.info("Closed Jade emulator '\(path)'", context: Self.logContext)
        }
        return Self.success
    }

    func closeAll() {
        let paths = lock.withLock { Array(sockets.keys) }
        paths.forEach { closeDevice(path: $0) }
    }

    func write(path: String, data: Data) -> JadeTransportResult {
        let notOpen = JadeTransportResult(success: false, error: "Device not open: '\(path)'", errorCode: .notConnected)
        return withSocket(path, notOpen: notOpen) { socket in
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { buffer in
                    send(socket.fd, buffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
                }
                if written <= 0 {
                    let error = errno
                    guard dropAfterRemoteClose(socket, path: path) else { return notOpen }
                    return JadeTransportResult(success: false, error: "Jade emulator write failed: errno \(error)", errorCode: .disconnected)
                }
                offset += written
            }
            return Self.success
        }
    }

    func read(path: String, timeoutMs: UInt32) -> JadeTransportReadResult {
        let notOpen = JadeTransportReadResult(success: false, data: Data(), error: "Device not open: '\(path)'", errorCode: .notConnected)
        return withSocket(path, notOpen: notOpen) { socket in
            var poller = pollfd(fd: socket.fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(max(timeoutMs, 1), Self.readTimeoutMaxMs)))
            // Nothing received yet is the normal state while the device works or waits.
            guard ready > 0 else { return JadeTransportReadResult(success: true, data: Data(), error: "", errorCode: nil) }
            var buffer = [UInt8](repeating: 0, count: Self.readBufferBytes)
            let count = recv(socket.fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                guard dropAfterRemoteClose(socket, path: path) else { return notOpen }
                return JadeTransportReadResult(success: false, data: Data(), error: "Jade emulator closed the connection", errorCode: .disconnected)
            }
            return JadeTransportReadResult(success: true, data: Data(buffer[0 ..< count]), error: "", errorCode: nil)
        }
    }

    // MARK: - Helpers

    private static let success = JadeTransportResult(success: true, error: "", errorCode: nil)

    /// Runs one call on the path's socket and keeps its descriptor open until the call returns,
    /// so a close from another thread cannot hand the number to a new connection mid-call.
    private func withSocket<T>(_ path: String, notOpen: T, _ body: (EmulatorSocket) -> T) -> T {
        let socket: EmulatorSocket? = lock.withLock {
            guard let socket = sockets[path] else { return nil }
            socket.inFlight += 1
            return socket
        }
        guard let socket else { return notOpen }
        defer {
            let closeNow = lock.withLock {
                socket.inFlight -= 1
                return socket.isClosed && socket.inFlight == 0
            }
            if closeNow {
                Darwin.close(socket.fd)
            }
        }
        return body(socket)
    }

    /// Wakes pending calls at once; the descriptor is released when the last of them returns.
    private func retire(_ socket: EmulatorSocket) {
        let closeNow = lock.withLock {
            socket.isClosed = true
            Darwin.shutdown(socket.fd, SHUT_RDWR)
            return socket.inFlight == 0
        }
        if closeNow {
            Darwin.close(socket.fd)
        }
    }

    /// Drops a socket the emulator closed. False when it was closed here first, so a local close
    /// is not reported as the Jade disconnecting and a newer socket on the path stays open.
    private func dropAfterRemoteClose(_ socket: EmulatorSocket, path: String) -> Bool {
        let wasCurrent = lock.withLock {
            guard sockets[path] === socket else { return false }
            sockets[path] = nil
            return true
        }
        if wasCurrent {
            retire(socket)
        }
        return wasCurrent
    }

    private func connect() throws -> Int32 {
        guard let separator = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: separator)...]) else {
            throw JadeEmulatorError.invalidAddress(address)
        }
        let host = String(address[..<separator])
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // Resolves a hostname such as localhost as well as an IPv4 literal.
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &resolved) == 0, let found = resolved, let foundAddr = found.pointee.ai_addr else {
            throw JadeEmulatorError.invalidAddress(address)
        }
        defer { freeaddrinfo(found) }
        addr.sin_addr = foundAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }

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

private final class EmulatorSocket {
    let fd: Int32
    var inFlight = 0
    var isClosed = false

    init(fd: Int32) {
        self.fd = fd
    }
}
