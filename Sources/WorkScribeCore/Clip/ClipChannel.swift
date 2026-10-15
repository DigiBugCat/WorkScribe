import Foundation

/// The native host's line to the running app: a Unix domain socket in WorkScribe's Application Support folder.
///
/// Why a socket rather than a distributed notification or a file drop: it is request/response (the popup needs the
/// current meeting before sending, and every clip gets an ack), it listens on no network port, the folder is 0700 and
/// the socket 0600, and the app checks the peer's user ID. Distributed notifications are visible to every process
/// of the user and carry no reply; a file drop needs polling for the ack.
public enum ClipChannel {
    public static var defaultPath: String {
        if let path = ProcessInfo.processInfo.environment["WORKSCRIBE_CLIP_SOCKET"] { return path }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WorkScribe/clip.sock").path
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case pathTooLong, socket(Int32), notRunning, alreadyRunning, badResponse
        public var description: String {
            switch self {
            case .pathTooLong: "socket path is too long"
            case .socket(let code): "socket error \(code): \(String(cString: strerror(code)))"
            case .notRunning: "WorkScribe isn't running"
            case .alreadyRunning: "another WorkScribe is already receiving clips"
            case .badResponse: "WorkScribe sent an unreadable reply"
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func connect(_ path: String, timeout: TimeInterval) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, timeout)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno; close(fd)
            throw code == ENOENT || code == ECONNREFUSED ? Failure.notRunning : Failure.socket(code)
        }
        return fd
    }

    static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Sends one request and waits for its response (the native host's side).
    public static func send(_ request: ClipRequest, path: String = defaultPath, timeout: TimeInterval = 10) throws -> ClipResponse {
        let fd = try connect(path, timeout: timeout)
        defer { close(fd) }
        try ClipFraming.write(fd: fd, ClipProtocol.encode(request))
        let data = try ClipFraming.read(fd: fd, limit: ClipProtocol.maxResponseBytes)
        guard let response = try? JSONDecoder().decode(ClipResponse.self, from: data), response.id == request.id else {
            throw Failure.badResponse
        }
        return response
    }
}

/// The app's side of `ClipChannel`: accepts connections from the same user, validates each request with
/// `ClipProtocol.validate` (the socket is reachable by any of the user's processes, not only the native host) and
/// answers with the handler's response.
public final class ClipSocketServer: @unchecked Sendable {
    public let path: String
    let handler: @Sendable (ClipRequest) async -> ClipResponse
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var thread: Thread?

    public init(path: String = ClipChannel.defaultPath, handler: @escaping @Sendable (ClipRequest) async -> ClipResponse) {
        self.path = path; self.handler = handler
    }

    public func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A live socket means another instance; a dead one is left over from a crash.
        if FileManager.default.fileExists(atPath: path) {
            if let probe = try? ClipChannel.connect(path, timeout: 1) { close(probe); throw ClipChannel.Failure.alreadyRunning }
            unlink(path)
        }
        var address = try ClipChannel.address(path)
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ClipChannel.Failure.socket(errno) }
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0, chmod(path, 0o600) == 0, listen(socketFD, 8) == 0 else {
            let code = errno; close(socketFD); throw ClipChannel.Failure.socket(code)
        }
        lock.lock(); fd = socketFD; lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(socketFD) }
        thread.name = "WorkScribe clip socket"
        thread.start()
        self.thread = thread
    }

    public func stop() {
        lock.lock(); let socketFD = fd; fd = -1; lock.unlock()
        guard socketFD >= 0 else { return }
        shutdown(socketFD, SHUT_RDWR); close(socketFD)
        unlink(path)
    }

    deinit { stop() }

    private func acceptLoop(_ socketFD: Int32) {
        while true {
            let client = accept(socketFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // closed by stop()
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [handler] in Self.serve(client, handler: handler) }
        }
    }

    static func serve(_ client: Int32, handler: @escaping @Sendable (ClipRequest) async -> ClipResponse) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
        ClipChannel.setTimeout(client, 10)
        let data: Data
        do { data = try ClipFraming.read(fd: client, limit: ClipProtocol.maxRequestBytes) }
        catch {
            if case ClipFraming.Failure.tooLarge = error {
                try? ClipFraming.write(fd: client, ClipProtocol.encode(ClipResponse.failure("", "too_large", "Message too large")))
            }
            close(client); return
        }
        let request: ClipRequest
        do { request = try ClipProtocol.validate(data) }
        catch {
            let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String ?? ""
            try? ClipFraming.write(fd: client, ClipProtocol.encode(ClipResponse.failure(String(id.prefix(64)), "invalid", "\(error)")))
            close(client); return
        }
        Task.detached {
            let response = await handler(request)
            try? ClipFraming.write(fd: client, ClipProtocol.encode(response))
            close(client)
        }
    }
}
