import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIModelClientError: LocalizedError, Equatable {
    case invalidAddress, credentialUnavailable, settingsChanged, accessDenied
    case networkUnavailable, timedOut, rateLimited, requestRejected, invalidResponse
    case unsupportedEffort, contextLimitExceeded, appleUnavailable(String), appleFailed

    var errorDescription: String? {
        switch self {
        case .invalidAddress: AIModelText.localized("Enter a valid HTTPS API base URL.")
        case .credentialUnavailable: AIModelText.localized("The API key is unavailable. Check your model settings.")
        case .settingsChanged: AIModelText.localized("Model settings changed. Review the request again.")
        case .accessDenied: AIModelText.localized("The service denied access. Check the API key and model permissions.")
        case .networkUnavailable: AIModelText.localized("Could not reach the model service. Check your connection.")
        case .timedOut: AIModelText.localized("The model service timed out. Try again.")
        case .rateLimited: AIModelText.localized("The model service is busy or rate limited. Try again later.")
        case .requestRejected: AIModelText.localized("The model service rejected the request. Check its configuration.")
        case .invalidResponse: AIModelText.localized("The model service returned an unreadable response.")
        case .unsupportedEffort: AIModelText.localized("This model does not accept the selected reasoning effort.")
        case .contextLimitExceeded: AIModelText.localized("The request exceeded the model's context window.")
        case .appleUnavailable(let reason): reason
        case .appleFailed: AIModelText.localized("Apple's on-device model could not complete this request.")
        }
    }
}

enum AIModelClient {
    static let defaultContextLimit = 256_000
    static let unverifiedContextLimit = 4_096
    static let compatibleOutputLimit = 1_024
    static let appleOutputLimit = 256

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func baseURL(from text: String) -> URL? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        return parts.url
    }

    static func compatibleContextLimit(for profile: AIProviderProfile) -> Int {
        min(defaultContextLimit, profile.contextLimit ?? unverifiedContextLimit)
    }

    static func appleUnavailableReason(locale: Locale) -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return model.supportsLocale(locale) ? nil : AIModelText.localized("Apple's on-device model does not support this language.")
            case .unavailable(.deviceNotEligible):
                return AIModelText.localized("This device does not support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return AIModelText.localized("Turn on Apple Intelligence in Settings to use the on-device model.")
            case .unavailable(.modelNotReady):
                return AIModelText.localized("Apple's on-device model is not ready yet.")
            default:
                return AIModelText.localized("Apple's on-device model is unavailable.")
            }
        }
        #endif
        return AIModelText.localized("Apple's on-device model requires iOS 26 or later.")
    }

    static func appleContextLimit() -> Int? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), SystemLanguageModel.default.availability == .available {
            #if compiler(>=6.3)
            return min(defaultContextLimit, SystemLanguageModel.default.contextSize)
            #else
            return unverifiedContextLimit
            #endif
        }
        #endif
        return nil
    }

    static func appleTokenCount(system: String, input: String) async -> Int? {
        #if canImport(FoundationModels) && compiler(>=6.3)
        if #available(iOS 26.4, *), SystemLanguageModel.default.availability == .available {
            let model = SystemLanguageModel.default
            guard let instructions = try? await model.tokenCount(for: Instructions(system)),
                  let prompt = try? await model.tokenCount(for: Prompt(input)),
                  let schema = try? await model.tokenCount(for: AIAppleFactSelection.generationSchema) else { return nil }
            return instructions + prompt + schema
        }
        #endif
        return nil
    }

    static func completeApple(system: String, input: String, locale: Locale) async throws -> String {
        if let reason = appleUnavailableReason(locale: locale) { throw AIModelClientError.appleUnavailable(reason) }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let model = SystemLanguageModel.default
            let session = LanguageModelSession(model: model, instructions: Instructions(system))
            do {
                try Task.checkCancellation()
                let content = try await session.respond(
                    to: Prompt(input), generating: AIAppleFactSelection.self,
                    options: GenerationOptions(maximumResponseTokens: appleOutputLimit)
                ).content
                try Task.checkCancellation()
                return String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                #if compiler(>=6.4)
                if #available(iOS 27, *), let error = error as? LanguageModelError, case .contextSizeExceeded = error {
                    throw AIModelClientError.contextLimitExceeded
                }
                #endif
                if let error = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = error {
                    throw AIModelClientError.contextLimitExceeded
                }
                throw AIModelClientError.appleFailed
            }
        }
        #endif
        throw AIModelClientError.appleFailed
    }

    static func fetchModels(baseURL: URL, apiKey: String?) async throws -> [String] {
        let request = try modelListRequest(baseURL: baseURL, apiKey: apiKey)
        let response = try await perform(request)
        guard let body = try? JSONDecoder().decode(ModelList.self, from: response) else {
            throw AIModelClientError.invalidResponse
        }
        let ids = body.data.lazy.map(\.id).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Set(ids).sorted()
    }

    static func completeCompatible(system: String, input: String, profile: AIProviderProfile, apiKey: String?) async throws -> String {
        let request = try completionRequest(system: system, input: input, profile: profile, apiKey: apiKey)
        let response = try await perform(request)
        guard let body = try? JSONDecoder().decode(ChatResponse.self, from: response),
              let content = body.choices.first?.message.content else { throw AIModelClientError.invalidResponse }
        return try usableContent(content)
    }

    static func modelListRequest(baseURL: URL, apiKey: String?) throws -> URLRequest {
        try request(baseURL: baseURL, path: ["models"], apiKey: apiKey)
    }

    static func completionRequest(system: String, input: String, profile: AIProviderProfile, apiKey: String?) throws -> URLRequest {
        var request = try request(baseURL: profile.baseURL, path: ["chat", "completions"], apiKey: apiKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: profile.model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: input)],
            reasoning_effort: profile.effort,
            max_completion_tokens: compatibleOutputLimit
        ))
        return request
    }

    private static func request(baseURL: URL, path: [String], apiKey: String?) throws -> URLRequest {
        guard let base = self.baseURL(from: baseURL.absoluteString) else { throw AIModelClientError.invalidAddress }
        let url = path.reduce(base) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            guard key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw AIModelClientError.credentialUnavailable }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: AIModelRedirectHandler())
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw AIModelClientError.invalidResponse }
            let maxBytes = 1_048_576
            guard response.expectedContentLength <= Int64(maxBytes) else { throw AIModelClientError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maxBytes else { throw AIModelClientError.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard (200...299).contains(response.statusCode) else { throw rejection(status: response.statusCode, body: data) }
            return data
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw error.code == .timedOut ? AIModelClientError.timedOut : AIModelClientError.networkUnavailable
        }
    }

    static func rejection(status: Int, body: Data) -> AIModelClientError {
        switch status {
        case 400, 422:
            let error = (try? JSONDecoder().decode(ProviderRejection.self, from: body))?.error
            let code = error?.code?.lowercased() ?? ""
            let param = error?.param?.lowercased() ?? ""
            let message = error?.message?.lowercased() ?? ""
            if code == "context_length_exceeded" || code == "context_window_exceeded" || message.contains("maximum context length") {
                return .contextLimitExceeded
            }
            if param == "reasoning_effort" || code == "unsupported_reasoning_effort" || message.contains("reasoning_effort") {
                return .unsupportedEffort
            }
            return .requestRejected
        case 401, 403: return .accessDenied
        case 413: return .contextLimitExceeded
        case 429: return .rateLimited
        default: return .requestRejected
        }
    }

    private static func usableContent(_ content: String) throws -> String {
        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AIModelClientError.invalidResponse }
        return result
    }
}

#if canImport(FoundationModels)
@available(iOS 26, *)
@Generable
private struct AIAppleFactSelection: Encodable {
    @Guide(description: "Answer only when the supplied facts answer the request.", .anyOf(["answer", "out_of_scope"]))
    let status: String

    @Guide(description: "Unique supplied fact IDs in desired order. Empty for out of scope.", .maximumCount(8))
    let factIDs: [String]
}
#endif

final class AIModelRedirectHandler: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

private struct ModelList: Decodable {
    struct Item: Decodable { let id: String }
    let data: [Item]
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let reasoning_effort: AIReasoningEffort
    let max_completion_tokens: Int
    let store = false
    let stream = false
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }

    let choices: [Choice]
}

private struct ProviderRejection: Decodable {
    struct Detail: Decodable {
        let code: String?
        let param: String?
        let message: String?
    }

    let error: Detail
}
