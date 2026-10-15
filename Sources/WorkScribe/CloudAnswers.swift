import Foundation
import Security
import SwiftUI
import WorkScribeCore

/// How a cloud request is authenticated. Today: an API key the user pastes in Settings (Keychain).
/// TODO(siwc): "Sign in with ChatGPT" (developers.openai.com/siwc) as a second conformer that runs the official OAuth
/// flow and refreshes its own token; `OpenAIResponsesGenerator` only asks for a bearer value.
protocol OpenAICredential: Sendable {
    func bearerToken() async throws -> String
}

struct StoredAPIKey: OpenAICredential {
    let key: String
    func bearerToken() async throws -> String { key }
}

/// The OpenAI key lives only in the login Keychain (never in files, defaults or logs).
enum Keychain {
    static let service = "local.workscribe.openai"
    static let account = "api-key"

    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String) -> Bool {
        delete()
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

enum CloudSettings {
    /// "Use cloud models": on by default once a key is set.
    static var useCloud: Bool {
        get { UserDefaults.standard.object(forKey: "useCloudModels") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useCloudModels") }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: "cloudModel").flatMap { $0.isEmpty ? nil : $0 } ?? OpenAIResponses.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "cloudModel") }
    }
    /// Cached after the first read so asking doesn't hit the Keychain each time.
    nonisolated(unsafe) private static var cached: String??
    static func apiKey() -> String? {
        // Keep isolated verification independent of the login Keychain.
        if ProcessInfo.processInfo.environment["WORKSCRIBE_DISABLE_CLOUD"] == "1" { return nil }
        if let cached { return cached }
        let value = Keychain.read().flatMap { $0.isEmpty ? nil : $0 }
        cached = .some(value)
        return value
    }
    static func setAPIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { Keychain.delete(); cached = .some(nil) } else { Keychain.write(trimmed); cached = .some(trimmed) }
    }
}

/// Small, fast OpenAI models through the Responses API, streamed. Sends only the bounded prompt (question + retrieved
/// snippets, see `OpenAIResponses`).
struct OpenAIResponsesGenerator: AnswerGenerator {
    let credential: any OpenAICredential
    let model: String
    var endpoint = OpenAIResponses.endpoint

    var displayName: String { "\(model) · OpenAI" }
    var provider: String { "openai" }
    var modelName: String { model }
    var isAvailable: Bool { true }

    func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try OpenAIResponses.request(prompt, model: model, apiKey: try await credential.bearerToken(), endpoint: endpoint)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count > 64 * 1024 { break } }
                        throw CaptureError.message(OpenAIResponses.errorMessage(body, status: status))
                    }
                    for try await line in bytes.lines {
                        switch OpenAIResponses.parse(line: line) {
                        case .delta(let text)?: continuation.yield(text)
                        case .completed?: continuation.finish(); return
                        case .failed(let message)?: throw CaptureError.message(message)
                        default: continue
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Cloud first; on-device when the cloud fails before writing anything (offline, bad key, quota).
struct FallbackAnswerGenerator: AnswerGenerator {
    let primary: any AnswerGenerator
    let fallback: any AnswerGenerator
    var displayName: String { primary.displayName }
    var provider: String { primary.provider }
    var modelName: String { primary.modelName }
    var isAvailable: Bool { primary.isAvailable || fallback.isAvailable }

    func stream(_ prompt: AskPrompt) -> AsyncThrowingStream<String, Error> {
        stream(prompt, provenance: AnswerProvenance())
    }
    func stream(_ prompt: AskPrompt, provenance: AnswerProvenance) -> AsyncThrowingStream<String, Error> {
        provenance.set(model: primary.displayName, provider: primary.provider)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var wrote = false
                do {
                    for try await delta in primary.stream(prompt) { wrote = true; continuation.yield(delta) }
                    continuation.finish()
                } catch {
                    guard !wrote, !Task.isCancelled, fallback.isAvailable else { continuation.finish(throwing: error); return }
                    provenance.set(model: fallback.displayName, provider: fallback.provider, fallback: "Cloud unavailable; answered on this Mac")
                    do {
                        for try await delta in fallback.stream(prompt) { continuation.yield(delta) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Settings › Answers: the cloud switch, the key (Keychain) and the model.
struct CloudSettingsView: View {
    let saved: () -> Void
    @State private var useCloud = CloudSettings.useCloud
    @State private var key = ""
    @State private var model = CloudSettings.model
    @State private var hasKey = CloudSettings.apiKey() != nil

    var body: some View {
        VStack(spacing: 0) {
        Form {
            Section {
                Toggle("Use cloud models for answers", isOn: $useCloud)
                Text("Ask, quick ask and live answers send your question and a few short excerpts (never whole transcripts, audio or screenshots) to OpenAI. Without a key, or offline, answers are written on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("OpenAI") {
                SecureField(hasKey ? "Key saved in Keychain · paste to replace" : "API key (sk-…)", text: $key)
                TextField("Model", text: $model)
                if hasKey { Button("Remove saved key", role: .destructive) { CloudSettings.setAPIKey(nil); hasKey = false } }
                Text("Sign in with ChatGPT is planned as another option.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        HStack {
            Spacer()
                Button("Save") {
                    CloudSettings.useCloud = useCloud
                    CloudSettings.model = model.trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { CloudSettings.setAPIKey(key); key = ""; hasKey = true }
                    saved()
                }.keyboardShortcut(.defaultAction)
        }.padding(12)
        }
        .frame(width: 440, height: 340)
    }
}
