// WorkScribe's native messaging host for the "WorkScribe Clip" browser extension.
//
// The browser starts this process when the extension calls `sendNativeMessage`, passing the caller's origin
// (`chrome-extension://<id>/`) as the first argument and framed JSON on stdin. The host:
//   1. refuses callers whose origin isn't on the allowlist (the built-in extension ID plus
//      ~/Library/Application Support/WorkScribe/NativeHost/allowed-origins.txt, written by the installer);
//   2. checks each message's size and schema (`ClipProtocol.validate`);
//   3. forwards it to the running app over its Unix socket and relays the app's acknowledgement.
// It opens no network connection, writes no files and never interprets page content.
import Foundation
import WorkScribeCore

setvbuf(stdout, nil, _IONBF, 0)

func reply(_ response: ClipResponse) {
    guard var data = try? ClipProtocol.encode(response) else { return }
    if data.count > ClipProtocol.maxResponseBytes {
        data = (try? ClipProtocol.encode(ClipResponse.failure(response.id, "failed", "Reply too large"))) ?? Data()
    }
    try? ClipFraming.write(fd: STDOUT_FILENO, data)
}

let arguments = CommandLine.arguments.dropFirst()
let origin = arguments.first { $0.hasPrefix("chrome-extension://") }
let allowlist = ClipProtocol.allowedOrigins(file: FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/WorkScribe/NativeHost/allowed-origins.txt"))
guard ClipProtocol.originAllowed(origin, allowed: allowlist) else {
    reply(.failure("", "origin", "This extension isn't allowed to talk to WorkScribe"))
    exit(1)
}

while true {
    let data: Data
    do { data = try ClipFraming.read(fd: STDIN_FILENO, limit: ClipProtocol.maxRequestBytes) }
    catch ClipFraming.Failure.closed { exit(0) }
    catch ClipFraming.Failure.tooLarge(let bytes) {
        // The rest of the oversized message can't be skipped safely: answer and stop.
        reply(.failure("", "too_large", "The page is too large to clip (\(bytes / 1024) KB)"))
        exit(1)
    }
    catch { exit(1) }

    let request: ClipRequest
    do { request = try ClipProtocol.validate(data) }
    catch {
        let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
        reply(.failure(id.flatMap { UUID(uuidString: $0) != nil ? $0 : nil } ?? "", "invalid", "\(error)"))
        continue
    }
    do { reply(try ClipChannel.send(request)) }
    catch ClipChannel.Failure.notRunning { reply(.failure(request.id, "not_running", "Open WorkScribe, then try again")) }
    catch { reply(.failure(request.id, "failed", "\(error)")) }
}
