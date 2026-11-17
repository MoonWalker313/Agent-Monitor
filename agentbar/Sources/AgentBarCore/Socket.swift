import Foundation
import Darwin

public enum SocketError: Error, CustomStringConvertible, Equatable {
    case pathTooLong(String)
    case syscall(String, Int32)
    case alreadyRunning(String)
    case notRunning(String)
    case badReply
    case timedOut

    public var description: String {
        switch self {
        case .pathTooLong(let p): return "socket path is too long for a Unix socket (\(p.utf8.count) bytes): \(p)"
        case .syscall(let name, let err): return "\(name) failed: \(String(cString: strerror(err)))"
        case .alreadyRunning(let p): return "another AgentBar is already listening on \(p)"
        case .notRunning(let p): return "AgentBar is not running (no listener at \(p))"
        case .badReply: return "unexpected reply from AgentBar"
        case .timedOut: return "timed out waiting for AgentBar"
        }
    }
}

func makeUnixAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: bytes)
        buf[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

private func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

private func setNoSigPipe(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

/// Local event listener (PRD D3 / plan §4.2):
/// - Unix domain socket only, no TCP. Directory 0700, socket 0600.
/// - Every connection's peer UID is checked with getpeereid; other users are refused.
/// - Newline-delimited JSON, 16 KB per line, one reply line per event.
public final class SocketServer: @unchecked Sendable {
    /// Receives a validated event; the server adds any validation warnings to the reply.
    public typealias Handler = @Sendable (DecodedEvent) -> ServerReply

    /// Identifies a permission request whose agent is waiting on this connection for Allow/Deny.
    public struct AwaitInfo: Hashable, Sendable {
        public let sessionKey: String
        public let requestID: String
        public init(sessionKey: String, requestID: String) {
            self.sessionKey = sessionKey
            self.requestID = requestID
        }
    }

    public enum AwaitEnd: Sendable {
        /// Nobody answered within `await_seconds`; the agent was told to ask in its own UI.
        case expired
        /// The agent closed the connection (it was cancelled, or answered elsewhere).
        case agentGone
    }

    public static let maxClients = 64
    public static let clientTimeout: TimeInterval = 5

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.agentbar.socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var awaiting: [AwaitInfo: Client] = [:]
    private var _rejectedPeers = 0
    private var _rateLimited = 0
    private let rateLimiter: RateLimiter
    public var log: (@Sendable (String) -> Void)?
    /// Answers `{"query": name}` lines with one JSON line (nil = unknown query). Runs on the server queue.
    public var onQuery: (@Sendable (String) -> Data?)?
    /// Called on the server's queue when an awaited request ends without a decision from `resolve`.
    public var onAwaitEnded: (@Sendable (AwaitInfo, AwaitEnd) -> Void)?

    private final class Client {
        let fd: Int32
        var buffer = Data()
        var source: DispatchSourceRead?
        var awaiting: AwaitInfo?
        var awaitWarnings: [String] = []
        init(fd: Int32) { self.fd = fd }
    }

    private enum LineResult {
        case raw(Data)
        case reply(ServerReply)
        case await(AwaitInfo, seconds: Int, warnings: [String])
    }

    public init(path: String, rateLimiter: RateLimiter = RateLimiter(), handler: @escaping Handler) {
        self.path = path
        self.rateLimiter = rateLimiter
        self.handler = handler
    }

    /// Number of events refused by the per-session rate limit.
    public var rateLimitedEvents: Int { queue.sync { _rateLimited } }

    /// Number of connections refused because they came from another user.
    public var rejectedPeers: Int { queue.sync { _rejectedPeers } }

    /// Requests whose agents are currently waiting for an answer.
    public var awaitingRequests: [AwaitInfo] { queue.sync { Array(awaiting.keys) } }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)

        var addr = try makeUnixAddress(path)

        // Don't steal the socket from a live instance: if something answers, bail out.
        if FileManager.default.fileExists(atPath: path) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            if probe >= 0 {
                let rc = withSockaddr(&addr) { connect(probe, $0, $1) }
                close(probe)
                if rc == 0 { throw SocketError.alreadyRunning(path) }
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }
        guard withSockaddr(&addr, { bind(fd, $0, $1) }) == 0 else {
            let err = errno; close(fd); throw SocketError.syscall("bind", err)
        }
        guard chmod(path, 0o600) == 0 else {
            let err = errno; close(fd); unlink(path); throw SocketError.syscall("chmod", err)
        }
        guard listen(fd, 64) == 0 else {
            let err = errno; close(fd); unlink(path); throw SocketError.syscall("listen", err)
        }
        setNonBlocking(fd)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
    }

    /// Stops listening. Agents still waiting for an answer are told to ask in their own UI.
    public func stop() {
        queue.sync {
            for (_, client) in awaiting {
                client.awaiting = nil
                _ = reply(ServerReply(ok: true, decision: .deferred), to: client)
            }
            awaiting.removeAll()
            for client in clients.values { client.source?.cancel() }
            clients.removeAll()
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
        }
        unlink(path)
    }

    /// Sends the user's answer to the waiting agent. Returns false if the agent is no longer waiting.
    @discardableResult
    public func resolve(_ info: AwaitInfo, decision: Decision, message: String? = nil) -> Bool {
        queue.sync {
            guard let client = awaiting.removeValue(forKey: info) else { return false }
            client.awaiting = nil
            let delivered = reply(ServerReply(ok: true, warnings: client.awaitWarnings.isEmpty ? nil : client.awaitWarnings,
                                              decision: decision, decisionMessage: message), to: client)
            drop(client)
            return delivered
        }
    }

    private func acceptPending() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { return } // EAGAIN: nothing left to accept

            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(cfd, &uid, &gid) == 0, uid == getuid() else {
                _rejectedPeers += 1
                log?("refused connection from uid \(uid)")
                close(cfd)
                continue
            }
            guard clients.count < Self.maxClients else {
                log?("refused connection: too many clients")
                close(cfd)
                continue
            }
            setNoSigPipe(cfd)
            setNonBlocking(cfd)

            let client = Client(fd: cfd)
            let source = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: queue)
            source.setEventHandler { [weak self, unowned client] in self?.readFrom(client) }
            source.setCancelHandler { close(cfd) }
            client.source = source
            clients[cfd] = client
            source.resume()

            // Idle timeout — except for connections waiting on a decision, which have their own deadline.
            queue.asyncAfter(deadline: .now() + Self.clientTimeout) { [weak self, weak client] in
                guard let self, let client, self.clients[client.fd] === client, client.awaiting == nil else { return }
                self.drop(client)
            }
        }
    }

    private func readFrom(_ client: Client) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client.fd, &chunk, chunk.count)
            if n > 0 {
                client.buffer.append(contentsOf: chunk[0..<n])
                if client.buffer.count > EventCodec.maxLineBytes * 4 { break } // process before growing more
                continue
            }
            if n == 0 { // EOF: handle a final unterminated line, then close
                guard processLines(client) else { return }
                if !client.buffer.isEmpty {
                    let line = client.buffer
                    client.buffer = Data()
                    guard handle(line, from: client) else { return }
                }
                if let info = client.awaiting { // the waiting agent went away
                    awaiting[info] = nil
                    client.awaiting = nil
                    onAwaitEnded?(info, .agentGone)
                }
                drop(client)
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { break }
            if let info = client.awaiting {
                awaiting[info] = nil
                client.awaiting = nil
                onAwaitEnded?(info, .agentGone)
            }
            drop(client)
            return
        }
        _ = processLines(client)
    }

    /// Returns false if the client was dropped.
    private func processLines(_ client: Client) -> Bool {
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            let line = client.buffer[client.buffer.startIndex..<newline]
            client.buffer = Data(client.buffer[client.buffer.index(after: newline)...])
            if line.count > EventCodec.maxLineBytes {
                _ = reply(.failure(EventValidationError.tooLarge.description), to: client)
                drop(client)
                return false
            }
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            guard handle(Data(line), from: client) else { return false }
        }
        if client.buffer.count > EventCodec.maxLineBytes {
            _ = reply(.failure(EventValidationError.tooLarge.description), to: client)
            drop(client)
            return false
        }
        return true
    }

    /// Returns false if the client was dropped.
    private func handle(_ line: Data, from client: Client) -> Bool {
        switch handleLine(line) {
        case .raw(let data):
            var out = data
            if out.last != 0x0A { out.append(0x0A) }
            writeAll(out, to: client)
            return true
        case .reply(let r):
            _ = reply(r, to: client)
            return true
        case .await(let info, let seconds, let warnings):
            guard client.awaiting == nil else {
                _ = reply(.failure("only one awaited request per connection"), to: client)
                return true
            }
            // A newer request for the same id replaces the old waiter.
            if let previous = awaiting[info] {
                previous.awaiting = nil
                _ = reply(ServerReply(ok: true, decision: .deferred), to: previous)
                drop(previous)
            }
            awaiting[info] = client
            client.awaiting = info
            client.awaitWarnings = warnings
            queue.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self, weak client] in
                guard let self, let client, self.awaiting[info] === client else { return }
                self.awaiting[info] = nil
                client.awaiting = nil
                _ = self.reply(ServerReply(ok: true, warnings: warnings.isEmpty ? nil : warnings, decision: .deferred), to: client)
                self.drop(client)
                self.onAwaitEnded?(info, .expired)
            }
            return true
        }
    }

    private func handleLine(_ line: Data) -> LineResult {
        if let name = StatusQuery.queryName(line) {
            if let data = onQuery?(name) { return .raw(data) }
            return .reply(.failure("unknown query '\(name)'"))
        }
        do {
            let decoded = try EventCodec.decode(line)
            let key = Session.key(agent: decoded.event.agent, sessionID: decoded.event.sessionID)
            guard rateLimiter.allow(key) else {
                _rateLimited += 1
                return .reply(.failure(EventValidationError.rateLimited.description))
            }
            var reply = handler(decoded)
            if !decoded.warnings.isEmpty { reply.warnings = (reply.warnings ?? []) + decoded.warnings }
            if reply.ok, let seconds = decoded.event.awaitSeconds, let request = decoded.event.request {
                return .await(AwaitInfo(sessionKey: key, requestID: request.id), seconds: seconds, warnings: decoded.warnings)
            }
            return .reply(reply)
        } catch let error as EventValidationError {
            return .reply(.failure(error.description))
        } catch {
            return .reply(.failure("invalid event"))
        }
    }

    /// Returns true if the whole reply was written.
    private func reply(_ reply: ServerReply, to client: Client) -> Bool {
        guard let data = try? EventCodec.encodeLine(reply) else { return false }
        return writeAll(data, to: client)
    }

    @discardableResult
    private func writeAll(_ data: Data, to client: Client) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(client.fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // Big replies (status) can fill the socket buffer; wait briefly for the reader.
                    var pfd = pollfd(fd: client.fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 1_000) > 0 { continue }
                    return false
                }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    private func drop(_ client: Client) {
        guard clients[client.fd] === client else { return }
        clients[client.fd] = nil
        client.source?.cancel()
    }
}

/// Client used by the `agentbar` CLI.
public enum SocketClient {
    private static func connectSocket(_ path: String, timeout: TimeInterval) throws -> Int32 {
        var addr = try makeUnixAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }
        setNoSigPipe(fd)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard withSockaddr(&addr, { connect(fd, $0, $1) }) == 0 else {
            let err = errno
            close(fd)
            if err == ENOENT || err == ECONNREFUSED { throw SocketError.notRunning(path) }
            throw SocketError.syscall("connect", err)
        }
        return fd
    }

    /// Sends one awaited permission request (with `await_seconds`) and blocks until the user
    /// answers, the server defers, or `timeout` passes. Keeps the connection open while waiting:
    /// closing it tells AgentBar the agent stopped waiting.
    public static func request(_ line: Data, to path: String, timeout: TimeInterval) throws -> ServerReply {
        let fd = try connectSocket(path, timeout: timeout)
        defer { close(fd) }
        var payload = line
        if payload.last != 0x0A { payload.append(0x0A) }
        let wrote = payload.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard wrote else { throw SocketError.syscall("write", errno) }

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !received.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { received.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timedOut }
            throw SocketError.syscall("read", errno)
        }
        guard let first = received.split(separator: 0x0A).first,
              let reply = try? JSONDecoder().decode(ServerReply.self, from: Data(first)) else { throw SocketError.badReply }
        return reply
    }

    /// Sends one line and returns the first reply line as raw bytes (for queries).
    public static func rawRequest(_ line: Data, to path: String, timeout: TimeInterval) throws -> Data {
        let fd = try connectSocket(path, timeout: timeout)
        defer { close(fd) }
        var payload = line
        if payload.last != 0x0A { payload.append(0x0A) }
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { received.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timedOut }
            throw SocketError.syscall("read", errno)
        }
        guard let first = received.split(separator: 0x0A).first else { throw SocketError.badReply }
        return Data(first)
    }

    public static func send(_ lines: [Data], to path: String, timeout: TimeInterval = 2) throws -> [ServerReply] {
        let fd = try connectSocket(path, timeout: timeout)
        defer { close(fd) }

        var payload = Data()
        for var line in lines {
            if line.last != 0x0A { line.append(0x0A) }
            payload.append(line)
        }
        // If the server rejects a line it may reply and close while we're still writing
        // (EPIPE). Keep going and read whatever reply it already sent.
        var writeError: Int32 = 0
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { writeError = errno; return }
                offset += n
            }
        }
        shutdown(fd, SHUT_WR)

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { received.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 { break }
            if errno == EINTR { continue }
            if writeError != 0 || errno == ECONNRESET { break }
            throw SocketError.syscall("read", errno)
        }
        if received.isEmpty && writeError != 0 { throw SocketError.syscall("write", writeError) }
        let decoder = JSONDecoder()
        return try received.split(separator: 0x0A).map {
            guard let reply = try? decoder.decode(ServerReply.self, from: Data($0)) else { throw SocketError.badReply }
            return reply
        }
    }
}
