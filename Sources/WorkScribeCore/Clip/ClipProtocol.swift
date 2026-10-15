import Foundation

/// What the browser extension captured from a page. Everything in it is untrusted page data: stored and shown,
/// never interpreted as instructions to WorkScribe.
public struct PageCapture: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var site: String?
    public var selection: String?
    /// Readable text of the page (selection is preferred when present).
    public var text: String?
    public var description: String?
    public var author: String?
    /// Seconds into a playing video (YouTube), when the page had one.
    public var videoTime: Double?
    public init(url: String, title: String, site: String? = nil, selection: String? = nil, text: String? = nil,
                description: String? = nil, author: String? = nil, videoTime: Double? = nil) {
        self.url = url; self.title = title; self.site = site; self.selection = selection; self.text = text
        self.description = description; self.author = author; self.videoTime = videoTime
    }
}

/// Extension → native host → app. Version 1.
public struct ClipRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case status, clip, ask }
    public var v: Int
    /// A UUID chosen by the extension; echoed in the response.
    public var id: String
    public var type: Kind
    public var page: PageCapture?
    /// For `ask`: the user's question about the page.
    public var question: String?
    /// The meeting the popup showed as the destination; the app honours it if it still exists.
    public var meetingId: String?
    public init(v: Int = ClipProtocol.version, id: String = UUID().uuidString, type: Kind, page: PageCapture? = nil,
                question: String? = nil, meetingId: String? = nil) {
        self.v = v; self.id = id; self.type = type; self.page = page; self.question = question; self.meetingId = meetingId
    }
}

/// App → native host → extension.
public struct ClipResponse: Codable, Equatable, Sendable {
    public struct Destination: Codable, Equatable, Sendable {
        /// "meeting" or "inbox".
        public var kind: String
        public var title: String
        public var meetingId: String?
        /// Seconds into the meeting when the clip was received.
        public var offset: Double?
        /// The note written, vault-relative.
        public var path: String?
        public init(kind: String, title: String, meetingId: String? = nil, offset: Double? = nil, path: String? = nil) {
            self.kind = kind; self.title = title; self.meetingId = meetingId; self.offset = offset; self.path = path
        }
    }
    public var v: Int
    public var id: String
    public var ok: Bool
    /// Machine-readable failure: invalid, origin, too_large, not_running, timeout, failed.
    public var code: String?
    public var error: String?
    public var destination: Destination?
    /// Where the vault is ("Work" or "WorkScribe notes"), for the popup.
    public var vault: String?
    public init(id: String, ok: Bool, code: String? = nil, error: String? = nil, destination: Destination? = nil, vault: String? = nil) {
        v = ClipProtocol.version; self.id = id; self.ok = ok; self.code = code; self.error = error
        self.destination = destination; self.vault = vault
    }
    public static func failure(_ id: String, _ code: String, _ message: String) -> ClipResponse {
        ClipResponse(id: id, ok: false, code: code, error: message)
    }
}

public enum ClipProtocol {
    public static let version = 1
    /// Native messaging host name registered with the browsers.
    public static let hostName = "com.workscribe.clipper"
    /// The extension's ID, fixed by the public `key` in `extras/chrome-extension/manifest.json`.
    public static let extensionID = "lcbgpofefjibjkigocjhkmjokpojgldd"
    public static let defaultAllowedOrigins: Set<String> = ["chrome-extension://\(extensionID)/"]

    /// Largest message accepted from the browser or on the app socket.
    public static let maxRequestBytes = 3 * 1024 * 1024
    /// Chrome refuses native-host messages over 1 MB.
    public static let maxResponseBytes = 1024 * 1024

    public struct Limits: Sendable {
        public var url = 4096, title = 1000, site = 200, selection = 200_000, text = 1_000_000
        public var description = 4000, author = 300, question = 4000
        public init() {}
    }

    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case tooLarge(Int), notJSON, unknownField(String), version(Int?), id, type, missingPage, url(String), tooLong(String), number(String), meetingID
        public var description: String {
            switch self {
            case .tooLarge(let bytes): "message is \(bytes) bytes; the limit is \(ClipProtocol.maxRequestBytes)"
            case .notJSON: "not a JSON object"
            case .unknownField(let name): "unknown field \(name)"
            case .version(let v): "unsupported version \(v.map(String.init) ?? "missing")"
            case .id: "id must be a UUID"
            case .type: "type must be status, clip or ask"
            case .missingPage: "clip and ask need a page"
            case .url(let reason): "url \(reason)"
            case .tooLong(let field): "\(field) is too long"
            case .number(let field): "\(field) must be a finite number of seconds"
            case .meetingID: "meetingId must be a UUID"
            }
        }
    }

    static let requestFields: Set<String> = ["v", "id", "type", "page", "question", "meetingId"]
    static let pageFields: Set<String> = ["url", "title", "site", "selection", "text", "description", "author", "videoTime"]

    /// Strict schema check of a raw request: size, exact field set, types, URL scheme, lengths. Strings come back
    /// with control characters removed and URL credentials stripped.
    public static func validate(_ data: Data, limits: Limits = Limits()) throws -> ClipRequest {
        guard data.count <= maxRequestBytes else { throw Invalid.tooLarge(data.count) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Invalid.notJSON }
        if let extra = Set(object.keys).subtracting(requestFields).sorted().first { throw Invalid.unknownField(extra) }
        if let page = object["page"] as? [String: Any], let extra = Set(page.keys).subtracting(pageFields).sorted().first {
            throw Invalid.unknownField("page.\(extra)")
        }
        guard let v = object["v"] as? Int, v == version else { throw Invalid.version(object["v"] as? Int) }
        guard let id = object["id"] as? String, UUID(uuidString: id) != nil else { throw Invalid.id }
        guard let rawType = object["type"] as? String, let type = ClipRequest.Kind(rawValue: rawType) else { throw Invalid.type }
        var request = ClipRequest(v: v, id: id, type: type)

        func string(_ dict: [String: Any], _ key: String, _ limit: Int, field: String, required: Bool = false) throws -> String? {
            guard let raw = dict[key], !(raw is NSNull) else {
                if required { throw Invalid.missingPage }
                return nil
            }
            guard let value = raw as? String else { throw Invalid.tooLong(field) }
            guard value.count <= limit else { throw Invalid.tooLong(field) }
            let clean = sanitize(value)
            return clean.isEmpty && !required ? nil : clean
        }

        if let rawMeeting = object["meetingId"], !(rawMeeting is NSNull) {
            guard let meeting = rawMeeting as? String, UUID(uuidString: meeting) != nil else { throw Invalid.meetingID }
            request.meetingId = meeting
        }
        request.question = try string(object, "question", limits.question, field: "question")
        if let page = object["page"] {
            guard let page = page as? [String: Any] else { throw Invalid.missingPage }
            guard let url = try string(page, "url", limits.url, field: "url", required: true) else { throw Invalid.missingPage }
            var capture = PageCapture(url: try cleanURL(url), title: try string(page, "title", limits.title, field: "title") ?? "")
            capture.site = try string(page, "site", limits.site, field: "site")
            capture.selection = try string(page, "selection", limits.selection, field: "selection")
            capture.text = try string(page, "text", limits.text, field: "text")
            capture.description = try string(page, "description", limits.description, field: "description")
            capture.author = try string(page, "author", limits.author, field: "author")
            if let time = page["videoTime"], !(time is NSNull) {
                guard let number = time as? Double, number.isFinite, number >= 0, number < 7 * 86400 else { throw Invalid.number("videoTime") }
                capture.videoTime = number
            }
            request.page = capture
        } else if type != .status {
            throw Invalid.missingPage
        }
        return request
    }

    /// http(s) only, no credentials, no fragment-only tricks.
    public static func cleanURL(_ raw: String) throws -> String {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)) else { throw Invalid.url("is not a URL") }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw Invalid.url("must be http or https")
        }
        guard let host = components.host, !host.isEmpty else { throw Invalid.url("needs a host") }
        components.scheme = scheme
        components.user = nil; components.password = nil
        guard let url = components.string else { throw Invalid.url("is not a URL") }
        return url
    }

    /// Removes control characters other than newline and tab.
    public static func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !(CharacterSet.controlCharacters.contains(scalar) || scalar.properties.generalCategory == .format && scalar != "\u{200D}")
        }))
    }

    /// Whether Chrome's caller origin (`chrome-extension://ID/`, the host's first argument) is allowed.
    public static func originAllowed(_ origin: String?, allowed: Set<String>) -> Bool {
        guard let origin else { return false }
        let normalized = origin.hasSuffix("/") ? origin : origin + "/"
        return allowed.contains(normalized)
    }

    /// Reads the allowlist file the installer writes (one origin per line, `#` comments), plus the built-in ID.
    public static func allowedOrigins(file: URL?) -> Set<String> {
        var out = defaultAllowedOrigins
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return out }
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.range(of: #"^chrome-extension://[a-p]{32}/?$"#, options: .regularExpression) != nil else { continue }
            out.insert(value.hasSuffix("/") ? value : value + "/")
        }
        return out
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

/// Native-messaging framing (also used on the app socket): a 4-byte little-endian length, then UTF-8 JSON.
public enum ClipFraming {
    public enum Failure: Error, Equatable { case closed, truncated, tooLarge(Int), io(Int32) }

    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        return Data(bytes: &length, count: 4) + payload
    }

    /// Reads one frame from a file descriptor. `closed` at a clean end of input, before any byte of a frame.
    public static func read(fd: Int32, limit: Int) throws -> Data {
        let header = try readExactly(fd: fd, count: 4, atStart: true)
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard length <= limit else { throw Failure.tooLarge(length) }
        return length == 0 ? Data() : try readExactly(fd: fd, count: length, atStart: false)
    }

    public static func write(fd: Int32, _ payload: Data) throws {
        let data = frame(payload)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure.io(errno)
                }
                offset += written
            }
        }
    }

    static func readExactly(fd: Int32, count: Int, atStart: Bool) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < count {
                let got = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
                if got == 0 { throw atStart && offset == 0 ? Failure.closed : Failure.truncated }
                if got < 0 {
                    if errno == EINTR { continue }
                    throw Failure.io(errno)
                }
                offset += got
            }
        }
        return data
    }
}
