import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIModelClientError: LocalizedError, Equatable {
    case invalidAddress, credentialUnavailable, settingsChanged, accessDenied
    case networkUnavailable, timedOut, rateLimited, requestRejected, invalidResponse
    case interruptedStream, invalidAttachments
    case modelListEndpointUnavailable(Int), modelListRequestFailed(Int)
    case unsupportedEffort, contextLimitExceeded, appleUnavailable(String), appleUnsupportedLanguage, appleFailed

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
        case .interruptedStream: AIModelText.localized("The model response ended before it was complete.")
        case .invalidAttachments: AIModelText.localized("The attachments exceed the allowed size or format.")
        case .modelListEndpointUnavailable(let status):
            AIModelText.localized("The model list endpoint is unavailable (HTTP \(status)). Check the service address.")
        case .modelListRequestFailed(let status):
            AIModelText.localized("The service could not list models (HTTP \(status)).")
        case .unsupportedEffort: AIModelText.localized("This model does not accept the selected reasoning effort.")
        case .contextLimitExceeded: AIModelText.localized("The request exceeded the model's context window.")
        case .appleUnavailable(let reason): reason
        case .appleUnsupportedLanguage: AIModelText.localized("Apple's on-device model does not support this language.")
        case .appleFailed: AIModelText.localized("Apple's on-device model could not complete this request.")
        }
    }
}

enum AIAppleAvailability: Equatable {
    case available, configurationUnavailable, disabled, waitingForModel, unsupportedLanguage, requiresOSUpdate, unavailable

    var unavailableReason: String? {
        switch self {
        case .available: nil
        case .configurationUnavailable:
            AIModelText.localized("Apple's on-device model is unavailable with this device configuration. Check Apple Intelligence settings and regional availability.")
        case .disabled: AIModelText.localized("Turn on Apple Intelligence in Settings to use the on-device model.")
        case .waitingForModel: AIModelText.localized("Apple's on-device model is not ready yet.")
        case .unsupportedLanguage: AIModelClientError.appleUnsupportedLanguage.errorDescription
        case .requiresOSUpdate: AIModelText.localized("Apple's on-device model requires iOS 26 or later.")
        case .unavailable: AIModelText.localized("Apple's on-device model is unavailable.")
        }
    }
}

enum AIModelClient {
    static let defaultContextLimit = 256_000
    static let unverifiedContextLimit = 4_096
    static let compatibleOutputLimit = 1_024
    static let appleOutputLimit = 256

    private static let session = makeSession(requestTimeout: 45, resourceTimeout: 90)
    private static let streamingSession = makeSession(requestTimeout: 90, resourceTimeout: 240)

    private static func makeSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }

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

    static func compatibleOutputLimit(for profile: AIProviderProfile) -> Int {
        guard profile.api == .responses, profile.requestsReasoningSummary else { return compatibleOutputLimit }
        return min(16_384, max(compatibleOutputLimit, compatibleContextLimit(for: profile) / 3))
    }

    static func appleUnavailableReason(locale: Locale) -> String? {
        appleAvailability(locale: locale).unavailableReason
    }

    static func appleAvailability(locale: Locale) -> AIAppleAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                let candidates = appleLocaleCandidates(locale: locale)
                return candidates.contains(where: { model.supportsLocale($0) }) ? .available : .unsupportedLanguage
            case .unavailable(.deviceNotEligible):
                return .configurationUnavailable
            case .unavailable(.appleIntelligenceNotEnabled):
                return .disabled
            case .unavailable(.modelNotReady):
                return .waitingForModel
            default:
                return .unavailable
            }
        }
        #endif
        return .requiresOSUpdate
    }

    static func appleLocaleCandidates(locale: Locale, preferredLanguages: [String] = Locale.preferredLanguages) -> [Locale] {
        let language = locale.language
        let regionlessLanguage = Locale.Language(components: .init(languageCode: language.languageCode, script: language.script))
        let matchingPreferredLocales = preferredLanguages.map(Locale.init(identifier:)).filter {
            $0.language.languageCode == language.languageCode && $0.language.script == language.script
        }
        return [locale] + matchingPreferredLocales + [
            Locale(identifier: language.maximalIdentifier),
            Locale(identifier: regionlessLanguage.maximalIdentifier)
        ]
    }

    @MainActor
    static func monitorAppleAvailability(locale: Locale, update: (AIAppleAvailability) -> Void) async {
        while !Task.isCancelled {
            let availability = appleAvailability(locale: locale)
            update(availability)
            guard availability == .waitingForModel else { return }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
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
                  let schema = try? await model.tokenCount(for: AIAppleReply.generationSchema) else { return nil }
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
                    to: Prompt(input), generating: AIAppleReply.self,
                    options: GenerationOptions(maximumResponseTokens: appleOutputLimit)
                ).content
                try Task.checkCancellation()
                return String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                #if compiler(>=6.4)
                if #available(iOS 27, *), let error = error as? LanguageModelError {
                    switch error {
                    case .contextSizeExceeded: throw AIModelClientError.contextLimitExceeded
                    case .unsupportedLanguageOrLocale: throw AIModelClientError.appleUnsupportedLanguage
                    default: break
                    }
                }
                #endif
                if let error = error as? LanguageModelSession.GenerationError {
                    switch error {
                    case .exceededContextWindowSize: throw AIModelClientError.contextLimitExceeded
                    case .unsupportedLanguageOrLocale: throw AIModelClientError.appleUnsupportedLanguage
                    default: break
                    }
                }
                throw AIModelClientError.appleFailed
            }
        }
        #endif
        throw AIModelClientError.appleFailed
    }

    static func fetchModels(baseURL: URL, apiKey: String?) async throws -> [String] {
        let request = try modelListRequest(baseURL: baseURL, apiKey: apiKey)
        let response = try await perform(request, isModelList: true)
        guard let body = try? JSONDecoder().decode(ModelList.self, from: response) else {
            throw AIModelClientError.invalidResponse
        }
        let ids = body.data.lazy.map(\.id).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Set(ids).sorted()
    }

    static func completeCompatible(system: String, input: String, profile: AIProviderProfile, apiKey: String?) async throws -> String {
        let request = try completionRequest(system: system, input: input, profile: profile, apiKey: apiKey)
        let response = try await perform(request)
        var decoder = AIProviderStreamDecoder(api: profile.api)
        let text = try decoder.consumeJSON(response).compactMap { update -> String? in
            if case .text(let text) = update { return text }
            return nil
        }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIModelClientError.invalidResponse }
        return trimmed
    }

    static func streamCompatible(
        system: String, input: String, profile: AIProviderProfile, apiKey: String?,
        attachments: [AIAssistantAttachment], generateImage: Bool,
        allowRecordChanges: Bool = false,
        onUpdate: @MainActor (AIStreamUpdate) -> Void
    ) async throws {
        let request = try compatibleRequest(system: system, input: input, profile: profile, apiKey: apiKey,
                                            attachments: attachments, generateImage: generateImage, stream: true,
                                            allowRecordChanges: allowRecordChanges)
        do {
            let (bytes, response) = try await streamingSession.bytes(for: request, delegate: AIModelRedirectHandler())
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw AIModelClientError.invalidResponse }
            guard (200...299).contains(response.statusCode) else {
                let data = try await readBody(bytes, response: response, limit: 1_048_576)
                throw rejection(status: response.statusCode, body: data)
            }

            var decoder = AIProviderStreamDecoder(api: profile.api,
                                                  includeReasoningSummary: profile.requestsReasoningSummary,
                                                  includeImages: generateImage,
                                                  allowRecordChanges: allowRecordChanges)
            if response.mimeType?.lowercased() != "text/event-stream" {
                let limit = generateImage ? AISSEResponseParser.eventByteLimit : 1_048_576
                let data = try await readBody(bytes, response: response, limit: limit)
                for update in try decoder.consumeJSON(data) {
                    try Task.checkCancellation()
                    await onUpdate(update)
                }
                return
            }

            var parser = AISSEResponseParser()
            for try await byte in bytes {
                guard let frame = try parser.consume(byte) else { continue }
                for update in try decoder.consume(frame) {
                    try Task.checkCancellation()
                    await onUpdate(update)
                }
                if decoder.finished { break }
            }
            try Task.checkCancellation()
            try decoder.validateCompletion()
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw error.code == .timedOut ? AIModelClientError.timedOut : AIModelClientError.networkUnavailable
        }
    }

    static func modelListRequest(baseURL: URL, apiKey: String?) throws -> URLRequest {
        try request(baseURL: baseURL, path: ["models"], apiKey: apiKey)
    }

    static func completionRequest(system: String, input: String, profile: AIProviderProfile, apiKey: String?) throws -> URLRequest {
        try compatibleRequest(system: system, input: input, profile: profile, apiKey: apiKey,
                              attachments: [], generateImage: false, stream: false)
    }

    static func compatibleRequest(
        system: String, input: String, profile: AIProviderProfile, apiKey: String?,
        attachments: [AIAssistantAttachment], generateImage: Bool, stream: Bool, allowRecordChanges: Bool = false
    ) throws -> URLRequest {
        let path = profile.api == .responses ? ["responses"] : ["chat", "completions"]
        var request = try request(baseURL: profile.baseURL, path: path, apiKey: apiKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept") }
        request.httpBody = try AIProviderRequestBody.encode(system: system, input: input, profile: profile,
                                                            attachments: attachments, generateImage: generateImage,
                                                            stream: stream, allowRecordChanges: allowRecordChanges)
        return request
    }

    private static func request(baseURL: URL, path: [String], apiKey: String?) throws -> URLRequest {
        guard let base = self.baseURL(from: baseURL.absoluteString),
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw AIModelClientError.invalidAddress }
        var basePath = parts.percentEncodedPath
        if let resource = ["/chat/completions", "/responses", "/models"].first(where: { basePath.hasSuffix($0) }) {
            basePath.removeLast(resource.count)
        } else if basePath.isEmpty {
            basePath = "/v1"
        }
        parts.percentEncodedPath = basePath + "/" + path.joined(separator: "/")
        guard let url = parts.url else { throw AIModelClientError.invalidAddress }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            guard key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw AIModelClientError.credentialUnavailable }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func perform(_ request: URLRequest, isModelList: Bool = false) async throws -> Data {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: AIModelRedirectHandler())
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw AIModelClientError.invalidResponse }
            if isModelList, !(200...299).contains(response.statusCode) {
                throw modelListRejection(status: response.statusCode)
            }
            let data = try await readBody(bytes, response: response, limit: 1_048_576)
            guard (200...299).contains(response.statusCode) else { throw rejection(status: response.statusCode, body: data) }
            return data
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw error.code == .timedOut ? AIModelClientError.timedOut : AIModelClientError.networkUnavailable
        }
    }

    private static func readBody(_ bytes: URLSession.AsyncBytes, response: HTTPURLResponse, limit: Int) async throws -> Data {
        guard response.expectedContentLength <= Int64(limit) else { throw AIModelClientError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw AIModelClientError.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    static func modelListRejection(status: Int) -> AIModelClientError {
        switch status {
        case 401, 403: .accessDenied
        case 404, 405: .modelListEndpointUnavailable(status)
        case 429: .rateLimited
        default: .modelListRequestFailed(status)
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
            if param == "reasoning_effort" || param == "reasoning.effort" || code == "unsupported_reasoning_effort"
                || message.contains("reasoning_effort") || message.contains("reasoning.effort") {
                return .unsupportedEffort
            }
            return .requestRejected
        case 401, 403: return .accessDenied
        case 413: return .contextLimitExceeded
        case 429: return .rateLimited
        default: return .requestRejected
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26, *)
@Generable
private struct AIAppleReply: Encodable {
    @Guide(description: "A concise, useful response in the user's language.")
    let answer: String

    @Guide(description: "Unique IDs of supplied record facts used in the answer. Empty if no facts were used.", .maximumCount(8))
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

private struct ProviderRejection: Decodable {
    struct Detail: Decodable {
        let code: String?
        let param: String?
        let message: String?
    }

    let error: Detail
}
