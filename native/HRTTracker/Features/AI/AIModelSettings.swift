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

struct AIProviderProfile: Codable, Equatable, Sendable {
    let baseURL: URL
    let model: String
    let effort: AIReasoningEffort
    let contextLimit: Int?
}

@MainActor
@Observable
final class AIModelSettings {
    private static let preferenceKey = "ai.compatibleProvider.v1"
    private(set) var profile: AIProviderProfile?
    private let inMemory: Bool
    private var inMemoryKey: String?

    init(inMemory: Bool = false) {
        self.inMemory = inMemory
        if !inMemory, let data = UserDefaults.standard.data(forKey: Self.preferenceKey) {
            profile = try? JSONDecoder().decode(AIProviderProfile.self, from: data)
        }
    }

    func apiKey(for profile: AIProviderProfile) throws -> String? {
        guard self.profile == profile else { throw AIModelClientError.settingsChanged }
        if inMemory { return inMemoryKey }
        return try AIProviderCredential.read(for: profile.baseURL)
    }

    func save(_ profile: AIProviderProfile, apiKey: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = key.isEmpty ? nil : key
        if inMemory {
            inMemoryKey = credential
        } else {
            let data = try JSONEncoder().encode(profile)
            try AIProviderCredential.write(credential, for: profile.baseURL)
            UserDefaults.standard.set(data, forKey: Self.preferenceKey)
        }
        self.profile = profile
    }

    func remove() throws {
        if inMemory {
            inMemoryKey = nil
        } else {
            try AIProviderCredential.delete()
            UserDefaults.standard.removeObject(forKey: Self.preferenceKey)
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
