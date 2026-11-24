import Foundation
import Observation
import Security

enum AIModelText {
    static func localized(_ key: String.LocalizationValue) -> String {
        label(key, table: "AIModels")
    }
}

enum AIReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, medium, high, xhigh, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: AIModelText.localized("Low")
        case .medium: AIModelText.localized("Medium")
        case .high: AIModelText.localized("High")
        case .xhigh: AIModelText.localized("Extra high")
        case .max: AIModelText.localized("Maximum")
        }
    }
}

enum AIExternalConfirmationMode: String, CaseIterable, Identifiable, Sendable {
    case firstSend, everySend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstSend: AIModelText.localized("First send")
        case .everySend: AIModelText.localized("Every send")
        }
    }
}

enum AIProviderAPI: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatCompletions, responses

    var id: Self { self }

    var title: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses API"
        }
    }
}

struct AIProviderProfile: Codable, Equatable, Sendable {
    let baseURL: URL
    let model: String
    let effort: AIReasoningEffort
    let contextLimit: Int?
    let api: AIProviderAPI
    let requestsReasoningSummary: Bool

    private enum CodingKeys: String, CodingKey {
        case baseURL, model, effort, contextLimit, api, requestsReasoningSummary
    }

    init(baseURL: URL, model: String, effort: AIReasoningEffort, contextLimit: Int?,
         api: AIProviderAPI = .responses, requestsReasoningSummary: Bool = false) {
        self.baseURL = baseURL
        self.model = model
        self.effort = effort
        self.contextLimit = contextLimit
        self.api = api
        self.requestsReasoningSummary = requestsReasoningSummary
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baseURL: try values.decode(URL.self, forKey: .baseURL),
            model: try values.decode(String.self, forKey: .model),
            effort: try values.decode(AIReasoningEffort.self, forKey: .effort),
            contextLimit: try values.decodeIfPresent(Int.self, forKey: .contextLimit),
            api: try values.decodeIfPresent(AIProviderAPI.self, forKey: .api) ?? .responses,
            requestsReasoningSummary: try values.decodeIfPresent(Bool.self, forKey: .requestsReasoningSummary) ?? false
        )
    }
}

@MainActor
@Observable
final class AIModelSettings {
    private static let preferenceKey = "ai.compatibleProvider.v1"
    private static let confirmationModeKey = "ai.externalConfirmationMode.v1"
    private static let sendingApprovalKey = "ai.externalSendingApproval.v1"
    private(set) var profile: AIProviderProfile?
    private(set) var confirmationMode: AIExternalConfirmationMode = .firstSend
    private(set) var sendingRevision = UUID()
    private var sendingApproval: SendingApproval?
    private let inMemory: Bool
    private let defaults: UserDefaults
    private var inMemoryKey: String?

    private struct SendingApproval: Codable {
        let baseURL: URL
        let model: String
        let api: AIProviderAPI?
        var includeMemory: Bool?
        var attachmentMemory: Bool?

        func matches(_ profile: AIProviderProfile) -> Bool {
            baseURL == profile.baseURL && model == profile.model && (api ?? .chatCompletions) == profile.api
        }
    }

    init(inMemory: Bool = false, defaults: UserDefaults = .standard) {
        self.inMemory = inMemory
        self.defaults = defaults
        guard !inMemory else { return }
        if let data = defaults.data(forKey: Self.preferenceKey) {
            profile = try? JSONDecoder().decode(AIProviderProfile.self, from: data)
        }
        confirmationMode = defaults.string(forKey: Self.confirmationModeKey)
            .flatMap(AIExternalConfirmationMode.init(rawValue:)) ?? .firstSend
        if let data = defaults.data(forKey: Self.sendingApprovalKey) {
            sendingApproval = try? JSONDecoder().decode(SendingApproval.self, from: data)
        }
    }

    var hasSendingApproval: Bool {
        guard let profile else { return false }
        return rememberedSending(for: profile) != nil || rememberedSending(for: profile, includesAttachments: true) != nil
    }

    func setConfirmationMode(_ mode: AIExternalConfirmationMode) {
        guard confirmationMode != mode else { return }
        revokeSendingApproval()
        confirmationMode = mode
        if !inMemory { defaults.set(mode.rawValue, forKey: Self.confirmationModeKey) }
    }

    func rememberedSending(for profile: AIProviderProfile, includesAttachments: Bool = false) -> Bool? {
        guard confirmationMode == .firstSend, self.profile == profile,
              let sendingApproval, sendingApproval.matches(profile) else { return nil }
        return includesAttachments ? sendingApproval.attachmentMemory : sendingApproval.includeMemory
    }

    func authorizeSending(for profile: AIProviderProfile, includeMemory: Bool, includesAttachments: Bool = false) {
        guard confirmationMode == .firstSend, self.profile == profile else { return }
        var approval = sendingApproval.flatMap { $0.matches(profile) ? $0 : nil }
            ?? SendingApproval(baseURL: profile.baseURL, model: profile.model, api: profile.api)
        if includesAttachments {
            approval.attachmentMemory = includeMemory
        } else {
            approval.includeMemory = includeMemory
        }
        if !inMemory {
            guard let data = try? JSONEncoder().encode(approval) else { return }
            defaults.set(data, forKey: Self.sendingApprovalKey)
        }
        sendingApproval = approval
    }

    func revokeSendingApproval() {
        sendingRevision = UUID()
        sendingApproval = nil
        if !inMemory { defaults.removeObject(forKey: Self.sendingApprovalKey) }
    }

    func apiKey(for profile: AIProviderProfile) throws -> String? {
        guard self.profile == profile else { throw AIModelClientError.settingsChanged }
        if inMemory { return inMemoryKey }
        return try AIProviderCredential.read(for: profile.baseURL)
    }

    func save(_ profile: AIProviderProfile, apiKey: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = key.isEmpty ? nil : key
        let recipientUnchanged = self.profile.map { current in
            current.baseURL == profile.baseURL && current.model == profile.model && current.api == profile.api
                && (try? self.apiKey(for: current) == credential) == true
        } ?? false
        if !recipientUnchanged { revokeSendingApproval() }
        if inMemory {
            inMemoryKey = credential
        } else {
            let data = try JSONEncoder().encode(profile)
            try AIProviderCredential.write(credential, for: profile.baseURL)
            defaults.set(data, forKey: Self.preferenceKey)
        }
        self.profile = profile
    }

    func remove() throws {
        revokeSendingApproval()
        if inMemory {
            inMemoryKey = nil
        } else {
            try AIProviderCredential.delete()
            defaults.removeObject(forKey: Self.preferenceKey)
        }
        profile = nil
    }
}

private enum AIProviderCredential {
    private struct StoredCredential: Codable {
        let baseURL: URL
        let apiKey: String
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.hellolaoyang.hrttracker.ai",
         kSecAttrAccount as String: "compatible-provider",
         kSecAttrSynchronizable as String: false]
    }

    static func read(for baseURL: URL) throws -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credential = try? JSONDecoder().decode(StoredCredential.self, from: data),
              credential.baseURL == baseURL else { throw AIModelClientError.credentialUnavailable }
        return credential.apiKey
    }

    static func write(_ apiKey: String?, for baseURL: URL) throws {
        guard let apiKey else { return try delete() }
        let data = try JSONEncoder().encode(StoredCredential(baseURL: baseURL, apiKey: apiKey))
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIModelClientError.credentialUnavailable }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIModelClientError.credentialUnavailable
        }
    }
}
