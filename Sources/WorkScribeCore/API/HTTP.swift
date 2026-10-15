import Foundation
import Security

/// A parsed HTTP/1.1 request. Header names are lowercased.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data
    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? APIJSON.encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    /// Status line, headers (plus Content-Length and Connection: close) and body.
    public func serialized() -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reason(status))"]
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        for key in all.keys.sorted() { lines.append("\(key): \(all[key]!)") }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    /// The head of a Server-Sent Events response; events follow with `SSE.event`.
    public static func eventStreamHead(extra: [String: String] = [:]) -> Data {
        var all = extra
        all["Content-Type"] = "text/event-stream; charset=utf-8"
        all["Cache-Control"] = "no-cache"
        all["Connection"] = "keep-alive"
        var lines = ["HTTP/1.1 200 OK"]
        for key in all.keys.sorted() { lines.append("\(key): \(all[key]!)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"; case 201: "Created"; case 204: "No Content"
        case 400: "Bad Request"; case 401: "Unauthorized"; case 403: "Forbidden"; case 404: "Not Found"
        case 405: "Method Not Allowed"; case 409: "Conflict"; case 413: "Payload Too Large"; case 422: "Unprocessable Entity"
        case 503: "Service Unavailable"
        default: status < 400 ? "OK" : "Error"
        }
    }
}

public enum HTTPParser {
    public enum Result: Equatable {
        /// More bytes are needed.
        case incomplete
        case complete(HTTPRequest)
        case invalid(status: Int, reason: String)
    }

    public static let maxHeaderBytes = 16 * 1024

    public static func parse(_ data: Data, maxBody: Int) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .invalid(status: 431, reason: "Headers too large") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, reason: "Headers are not UTF-8")
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400, reason: "Bad request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400, reason: "Bad header") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(status: 400, reason: "Chunked bodies are not supported") }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        guard length >= 0 else { return .invalid(status: 400, reason: "Bad Content-Length") }
        guard length <= maxBody else { return .invalid(status: 413, reason: "Body over \(maxBody) bytes") }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: String(parts[0]).uppercased(), path: components?.path ?? target,
                                     query: query, headers: headers, body: Data(body)))
    }
}

/// Token, Host and Origin checks for the loopback API.
public enum APIGuard {
    public static let allowedOrigin = "app://obsidian.md"

    /// DNS rebinding defence: only loopback names, with or without a port.
    public static func isLoopbackHost(_ host: String?) -> Bool {
        guard var host = host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            let rest = host[host.index(after: close)...]
            guard rest.isEmpty || (rest.hasPrefix(":") && Int(rest.dropFirst()) != nil) else { return false }
            return host[host.index(after: host.startIndex)..<close] == "::1"
        }
        if let colon = host.lastIndex(of: ":") {
            guard Int(host[host.index(after: colon)...]) != nil else { return false }
            host = String(host[..<colon])
        }
        return host == "127.0.0.1" || host == "localhost"
    }

    /// Nil when the request may proceed; otherwise the response to send.
    public static func check(_ request: HTTPRequest, token: String) -> HTTPResponse? {
        guard isLoopbackHost(request.headers["host"]) else { return .error(403, "Host must be 127.0.0.1 or localhost") }
        if let origin = request.headers["origin"], origin != allowedOrigin { return .error(403, "Origin not allowed") }
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer "),
              constantTimeEqual(String(header.dropFirst(7)), token) else {
            return .error(401, "Missing or wrong bearer token (see api.json)")
        }
        return nil
    }

    /// CORS headers: only for Obsidian's origin.
    public static func cors(_ request: HTTPRequest) -> [String: String] {
        guard request.headers["origin"] == allowedOrigin else { return [:] }
        return ["Access-Control-Allow-Origin": allowedOrigin, "Vary": "Origin",
                "Access-Control-Allow-Headers": "Authorization, Content-Type",
                "Access-Control-Allow-Methods": "GET, POST, PATCH, OPTIONS", "Access-Control-Max-Age": "600"]
    }

    /// Preflight answer (no token: browsers don't send one on OPTIONS).
    public static func preflight(_ request: HTTPRequest) -> HTTPResponse {
        guard isLoopbackHost(request.headers["host"]), request.headers["origin"] == allowedOrigin else {
            return .error(403, "Origin not allowed")
        }
        return HTTPResponse(status: 204, headers: cors(request))
    }

    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func randomToken(bytes: Int = 32) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        if SecRandomCopyBytes(kSecRandomDefault, bytes, &raw) != errSecSuccess {
            for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
        }
        return raw.map { String(format: "%02x", $0) }.joined()
    }
}

/// The discovery file the Obsidian plugin reads: `{"port":N,"token":"…","version":1}`, mode 0600.
public struct APIConfig: Codable, Equatable, Sendable {
    public var port: Int
    public var token: String
    public var version: Int
    public init(port: Int, token: String, version: Int = 1) { self.port = port; self.token = token; self.version = version }

    public static var defaultURL: URL {
        if let dir = ProcessInfo.processInfo.environment["WORKSCRIBE_API_DIR"] { return URL(fileURLWithPath: dir).appendingPathComponent("api.json") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorkScribe/api.json")
    }

    public func write(to url: URL = APIConfig.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Create with 0600 before writing the token, so it is never readable by others.
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: encoder.encode(self))
    }
}

/// Server-Sent Events framing.
public enum SSE {
    public static func event<T: Encodable>(_ name: String, _ value: T, id: Int? = nil) -> Data {
        let json = (try? APIJSON.encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var text = ""
        if let id { text += "id: \(id)\n" }
        text += "event: \(name)\n"
        for line in json.split(separator: "\n", omittingEmptySubsequences: false) { text += "data: \(line)\n" }
        return Data((text + "\n").utf8)
    }
    /// A comment line that keeps idle connections open.
    public static let keepAlive = Data(": keep-alive\n\n".utf8)
}

public enum APIJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
