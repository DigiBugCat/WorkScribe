import Foundation
import Network
import WorkScribeCore

/// One client connection: reads a single request, then either answers and closes, or stays open for an event stream.
final class APIConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false
    private let lock = NSLock()
    /// Called once when the peer goes away or the connection is closed.
    var onClose: (() -> Void)?

    init(_ connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }

    var isClosed: Bool { lock.withLock { closed } }

    func start(maxBody: Int, handle: @escaping (HTTPRequest) -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.markClosed()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(maxBody: maxBody, handle: handle)
    }

    private func receive(maxBody: Int, handle: @escaping (HTTPRequest) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer, maxBody: maxBody) {
            case .complete(let request):
                handle(request)
                watchForClose()
            case .invalid(let status, let reason):
                send(.error(status, reason), close: true)
            case .incomplete:
                if complete || error != nil { close() } else { receive(maxBody: maxBody, handle: handle) }
            }
        }
    }

    /// After the request, any read completing means the peer closed (clients send nothing more).
    private func watchForClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            if complete || error != nil { self?.close() } else { self?.watchForClose() }
        }
    }

    func send(_ response: HTTPResponse, close shouldClose: Bool = true) {
        write(response.serialized(), close: shouldClose)
    }

    func write(_ data: Data, close shouldClose: Bool = false) {
        guard !isClosed else { return }
        // Strong capture: the last write of a stream must still close the socket after its owner let go.
        connection.send(content: data, completion: .contentProcessed { [self] error in
            if error != nil || shouldClose { close() }
        })
    }

    func close() {
        guard !isClosed else { return }
        connection.cancel()
        markClosed()
    }

    private func markClosed() {
        let callback: (() -> Void)? = lock.withLock {
            if closed { return nil }
            closed = true
            let callback = onClose; onClose = nil
            return callback
        }
        callback?()
    }
}

/// The loopback HTTP server for the Obsidian plugin (docs/api/local-api.md): 127.0.0.1 only, a random free port,
/// a bearer token from `api.json`. Routing and JSON shapes live in WorkScribeCore (APIRoutes.swift); requests are
/// handled by `LocalAPI` on the main actor.
final class LocalAPIServer: @unchecked Sendable {
    static let maxBody = 1024 * 1024
    let token: String
    private let queue = DispatchQueue(label: "WorkScribe.api", qos: .userInitiated)
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let handle: @Sendable (HTTPRequest, APIConnection) -> Void

    init(token: String = APIGuard.randomToken(), handle: @escaping @Sendable (HTTPRequest, APIConnection) -> Void) {
        self.token = token; self.handle = handle
    }

    /// Binds and returns the port once listening.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { [weak self] state in
                guard once.claim() else { return }
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? 0
                    self?.port = port
                    continuation.resume(returning: port)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default: once.release()
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func accept(_ connection: NWConnection) {
        let client = APIConnection(connection, queue: queue)
        let token = token, handle = handle
        client.start(maxBody: Self.maxBody) { request in
            if request.method == "OPTIONS" { client.send(APIGuard.preflight(request)); return }
            if var refusal = APIGuard.check(request, token: token) {
                refusal.headers.merge(APIGuard.cors(request)) { $1 }
                client.send(refusal); return
            }
            handle(request, client)
        }
    }
}

/// Resumes a continuation once from a callback that can fire repeatedly.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// True the first time; later calls get false until `release`.
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    func release() { lock.withLock { done = false } }
}
