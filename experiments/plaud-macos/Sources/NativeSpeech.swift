import Foundation

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor final class NativeSpeech {
    private let runtime = SpeechRuntime()
    private var connection: SpeechConnection?
    private var pump: Task<Void, Never>?
    private var input: AsyncStream<Data>.Continuation?
    var onEvent: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?
    func start() async throws -> AsyncStream<Data>.Continuation {
        try await runtime.warmUp()
        let connection = SpeechConnection(runtime: runtime)
        connection.onEvent = { [weak self] in self?.onEvent?($0) }
        try await connection.connect(); self.connection = connection
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(512))
        input = continuation
        pump = Task { [weak self] in
            do { for await bytes in stream { try await connection.write(bytes) } }
            catch { self?.onError?(error.localizedDescription) }
        }
        return continuation
    }
    func finish() async {
        input?.finish(); input = nil
        await pump?.value; pump = nil
        do { try await connection?.finish() }
        catch { onError?(error.localizedDescription) }
        connection?.close(); connection = nil
        await runtime.closeStreams()
    }
    func shutdown() async { await finish(); await runtime.stop() }
}
