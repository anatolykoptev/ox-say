import Darwin
import Foundation

/// A TCP listener on 127.0.0.1 only, on an ephemeral port, that records every
/// connection made to it. It is the oracle for "this code never touches the
/// network": a page whose every link points here proves the claim by the
/// connection count staying at zero. Nothing else can reach it, and `stop()`
/// closes it.
final class LoopbackListener {
    /// How long a connection is given to send its request line.
    private static let requestWaitMilliseconds: Int32 = 200
    /// How often the accept loop looks at its stop flag.
    private static let pollMilliseconds: Int32 = 25
    private static let backlog: Int32 = 64
    private static let requestBufferBytes = 4096
    private static let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

    struct SetupError: Error { var step: String }

    let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var seen: [String] = []
    private var stopping = false
    private let finished = DispatchSemaphore(value: 0)

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SetupError(step: "socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, Self.backlog) == 0 else {
            close(fd)
            throw SetupError(step: "bind/listen")
        }
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard got == 0 else {
            close(fd)
            throw SetupError(step: "getsockname")
        }
        port = UInt16(bigEndian: named.sin_port)
        descriptor = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// `http://127.0.0.1:<port>`
    var origin: String { "http://127.0.0.1:\(port)" }

    /// One entry per connection so far: its request line, or "(no request)".
    var connections: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    /// Stops accepting and closes the socket; returns once the loop has ended.
    func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
        finished.wait()
        close(descriptor)
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func acceptLoop() {
        while true {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Self.pollMilliseconds)
            if ready > 0 {
                let client = accept(descriptor, nil, nil)
                if client >= 0 { serve(client) }
            } else if isStopping {
                break
            }
        }
        finished.signal()
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var poller = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        var line = "(no request)"
        if poll(&poller, 1, Self.requestWaitMilliseconds) > 0 {
            var buffer = [UInt8](repeating: 0, count: Self.requestBufferBytes)
            let count = read(client, &buffer, buffer.count)
            if count > 0 {
                let head = String(decoding: buffer[0..<count], as: UTF8.self)
                line = head.components(separatedBy: "\r\n").first ?? head
            }
        }
        lock.lock()
        seen.append(line)
        lock.unlock()
        _ = Self.notFound.withCString { write(client, $0, strlen($0)) }
    }
}
