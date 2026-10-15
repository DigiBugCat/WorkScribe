import Foundation

/// A `workscribe://` link to an exact moment, for MCP results, notes and search hits:
///
///     workscribe://meeting/<meeting-uuid>?t=<seconds>&segment=<segment-id>
///     workscribe://file?path=<percent-encoded absolute path>&page=<n>&t=<seconds>
public enum WorkScribeLink: Equatable, Sendable {
    case meeting(id: String, seconds: Double?, segment: String?)
    case file(path: String, page: Int?, seconds: Double?)

    public static let scheme = "workscribe"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { first, _ in first })
        let seconds = items["t"].flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        switch components.host?.lowercased() {
        case "meeting":
            let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard UUID(uuidString: id) != nil else { return nil }
            self = .meeting(id: id, seconds: seconds, segment: items["segment"].flatMap { $0.isEmpty ? nil : $0 })
        case "file":
            guard let path = items["path"], path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
            self = .file(path: path, page: items["page"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }, seconds: seconds)
        default: return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        var items: [URLQueryItem] = []
        func seconds(_ value: Double?) {
            if let value { items.append(URLQueryItem(name: "t", value: String(format: "%.1f", value))) }
        }
        switch self {
        case .meeting(let id, let t, let segment):
            components.host = "meeting"; components.path = "/" + id
            seconds(t)
            if let segment { items.append(URLQueryItem(name: "segment", value: segment)) }
        case .file(let path, let page, let t):
            components.host = "file"
            items.append(URLQueryItem(name: "path", value: path))
            if let page { items.append(URLQueryItem(name: "page", value: String(page))) }
            seconds(t)
        }
        // queryItems leaves "&", "=" and "+" alone; a file name can hold any of them.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        components.percentEncodedQueryItems = items.isEmpty ? nil : items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return components.url!
    }
}
