import Foundation
import Security

struct PlaudSession: Codable {
    let userToken: String
    let subject: String
    let clientID: String
    let expiresAt: Date
}
struct PlaudHandshake {
    let subject: String
    let publicKey: String
    let privateKey: String
    let signature: String
}
enum PlaudAuthError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Do not forward credentials across redirects or emit response bodies in logs.
final class NoCredentialRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
actor PlaudAuth {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private let send: Transport
    private let base = URL(string: "https://platform-us.plaud.ai/developer/api/")!
    init(transport: Transport? = nil) {
        if let transport { send = transport }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 30
            let session = URLSession(configuration: configuration, delegate: NoCredentialRedirects(), delegateQueue: nil)
            send = { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw PlaudAuthError.message("Invalid server response") }
                return (data, response.statusCode)
            }
        }
    }
    func authenticate(clientID: String, secret: String, userID: String) async throws -> PlaudSession {
        guard !clientID.isEmpty, !clientID.contains(":"), !secret.isEmpty, (6...120).contains(userID.count) else {
            throw PlaudAuthError.message("Client ID, client secret, and a stable user ID are required")
        }
        let basic = Data("\(clientID):\(secret)".utf8).base64EncodedString()
        let partner = try await request("oauth/partner/access-token", authorization: "Basic " + basic, form: true)
        guard let partnerToken = partner["access_token"] as? String, !partnerToken.isEmpty else {
            throw PlaudAuthError.message("Partner access was not granted")
        }
        let user = try await request("open/partner/users/access-token", authorization: "Bearer " + partnerToken,
                                     body: ["user_id": userID, "expires_in": 86400])
        guard let token = user["access_token"] as? String, let subject = Self.subject(token) else {
            throw PlaudAuthError.message("User token did not contain a device identity")
        }
        return PlaudSession(userToken: token, subject: subject, clientID: clientID,
                            expiresAt: Date().addingTimeInterval(user["expires_in"] as? Double ?? 3600))
    }
    func prepare(session: PlaudSession, serial: String) async throws -> PlaudHandshake {
        guard session.expiresAt > Date() else { throw PlaudAuthError.message("Developer session expired. Authenticate again.") }
        guard serial.hasPrefix("881") else { throw PlaudAuthError.message("This test currently targets Plaud Note Pro devices") }
        let auth = "Bearer " + session.userToken
        // Normal SDK connection verifies ownership through its signed BLE
        // handshake, then cloud bind. The recovery endpoint's is_bind flag
        // also reports true for this application's existing binding; it is
        // not a normal reconnect gate. No recovery/force-clear is performed.
        let key = try await request("open/partner/sdk/gen-key", authorization: auth)
        guard let publicKey = key["public_key"] as? String, !publicKey.isEmpty,
              let privateKey = key["private_key"] as? String, !privateKey.isEmpty else {
            throw PlaudAuthError.message("Plaud did not return a complete device key pair")
        }
        let signed = try await request("open/partner/sdk/sn-sign", authorization: auth, body: ["type": "notepro", "sn": serial])
        guard let signature = signed["signature"] as? String, !signature.isEmpty else {
            throw PlaudAuthError.message("Plaud did not authorize this device signature")
        }
        return PlaudHandshake(subject: session.subject, publicKey: publicKey, privateKey: privateKey, signature: signature)
    }
    // Called only after an explicitly requested device connection completes its BLE handshake.
    func bind(session: PlaudSession, serial: String) async throws {
        _ = try await request("open/partner/sdk/bind", authorization: "Bearer " + session.userToken,
                              body: ["type": "notepro", "sn": serial])
    }
    func unbind(session: PlaudSession, serial: String) async throws {
        _ = try await request("open/partner/sdk/unbind", authorization: "Bearer " + session.userToken,
                              body: ["type": "notepro", "sn": serial])
    }
    private func request(_ path: String, authorization: String, body: [String: Any] = [:], form: Bool = false, method: String = "POST", query: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(form ? "application/x-www-form-urlencoded" : "application/json", forHTTPHeaderField: "Content-Type")
        if method != "GET" { request.httpBody = form ? Data() : try JSONSerialization.data(withJSONObject: body) }
        let (data, code) = try await send(request)
        guard (200...299).contains(code) else {
            if code == 401 { throw PlaudAuthError.message("Plaud rejected the developer credentials or session") }
            if code == 403 { throw PlaudAuthError.message("Plaud denied access. Check developer permissions and device ownership.") }
            throw PlaudAuthError.message("Plaud request failed (HTTP \(code))")
        }
        if data.isEmpty { return [:] }
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaudAuthError.message("Invalid Plaud response format")
        }
        // Some SDK endpoints wrap their payload in `data`.
        return decoded["data"] as? [String: Any] ?? decoded
    }
    static func subject(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String, !subject.isEmpty else { return nil }
        return subject
    }
}

struct PlaudSessionStore {
    private let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.workscribe.plaud-lab", kSecAttrAccount as String: "developer-session"]
    func load() throws -> PlaudSession? {
        var request = query; request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw PlaudAuthError.message("Couldn’t read developer session from Keychain") }
        let session = try JSONDecoder().decode(PlaudSession.self, from: data)
        return session.expiresAt > Date() ? session : nil
    }
    func save(_ session: PlaudSession) throws {
        let bytes = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.merge(attributes) { _, value in value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PlaudAuthError.message("Couldn’t save developer session to Keychain") }
        } else if status != errSecSuccess { throw PlaudAuthError.message("Couldn’t update developer session in Keychain") }
    }
}
