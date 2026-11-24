import XCTest
@testable import HRTTracker

final class AIModelClientTests: XCTestCase {
    func testCompatibleEndpointsPreserveTheConfiguredBasePath() throws {
        let base = try XCTUnwrap(AIModelClient.baseURL(from: " HTTPS://LOCALHOST:19443/gateway/v1/ "))
        let request = try AIModelClient.modelListRequest(baseURL: base, apiKey: nil)
        XCTAssertEqual(request.url?.absoluteString, "https://localhost:19443/gateway/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.httpShouldHandleCookies)

        XCTAssertNil(AIModelClient.baseURL(from: "http://localhost:19443/v1"))
        XCTAssertNil(AIModelClient.baseURL(from: "https://user:password@localhost:19443/v1"))
        XCTAssertNil(AIModelClient.baseURL(from: "https://localhost:19443/v1?redirect=yes"))
        XCTAssertNil(AIModelClient.baseURL(from: "https://localhost:19443/v1#model"))
    }

    func testModelsAndCompletionsResolveFromPastedServiceAddresses() throws {
        let host = "https://localhost:19443"
        let cases = [
            ("", "/v1"),
            ("/v1/chat/completions/", "/v1"),
            ("/v1/responses", "/v1"),
            ("/v1/models", "/v1"),
            ("/gateway%20name/compatible", "/gateway%20name/compatible"),
            ("/gateway/v2/chat/completions", "/gateway/v2"),
            ("/models", "")
        ]
        for (pastedPath, expectedBasePath) in cases {
            let base = try XCTUnwrap(AIModelClient.baseURL(from: host + pastedPath))
            let models = try AIModelClient.modelListRequest(baseURL: base, apiKey: "fixture-key")
            XCTAssertEqual(models.url?.absoluteString, host + expectedBasePath + "/models")
            XCTAssertEqual(models.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            let profile = AIProviderProfile(baseURL: base, model: "fixture-model", effort: .medium, contextLimit: nil,
                                            api: .chatCompletions)
            let completion = try AIModelClient.completionRequest(system: "", input: "", profile: profile, apiKey: nil)
            XCTAssertEqual(completion.url?.absoluteString, host + expectedBasePath + "/chat/completions")
        }
    }

    func testModelListFailureDistinguishesMissingEndpointAndOtherServerFailures() {
        XCTAssertEqual(AIModelClient.modelListRejection(status: 401), .accessDenied)
        XCTAssertEqual(AIModelClient.modelListRejection(status: 404), .modelListEndpointUnavailable(404))
        XCTAssertEqual(AIModelClient.modelListRejection(status: 405), .modelListEndpointUnavailable(405))
        XCTAssertEqual(AIModelClient.modelListRejection(status: 429), .rateLimited)
        XCTAssertEqual(AIModelClient.modelListRejection(status: 502), .modelListRequestFailed(502))
    }

    func testAppleLocaleCandidatesUseThePreferredRegionWithoutSwitchingLanguageOrScript() {
        let candidates = AIModelClient.appleLocaleCandidates(
            locale: Locale(identifier: "zh-Hans-HK"),
            preferredLanguages: ["zh-Hans-CN", "zh-Hant-HK", "en-US"]
        )
        XCTAssertEqual(candidates.prefix(2).map(\.identifier), ["zh-Hans-HK", "zh-Hans-CN"])
        XCTAssertTrue(candidates.allSatisfy { $0.language.languageCode == .chinese && $0.language.script?.identifier == "Hans" })
        let normalized = AIModelClient.appleLocaleCandidates(locale: Locale(identifier: "zh-Hans-HK"), preferredLanguages: [])
        XCTAssertTrue(normalized.contains(Locale(identifier: "zh-Hans-CN")))
    }

    func testCompatibleCompletionIsStatelessAndUsesTheSelectedEffort() throws {
        let profile = try profile(effort: .xhigh)
        let request = try AIModelClient.completionRequest(
            system: "Fixture instruction", input: "Approved synthetic input", profile: profile, apiKey: "fixture-key"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://localhost:19443/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "fixture-model")
        XCTAssertEqual(json["reasoning_effort"] as? String, "xhigh")
        XCTAssertEqual(json["max_completion_tokens"] as? Int, AIModelClient.compatibleOutputLimit)
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["messages"] as? [[String: String]], [
            ["role": "system", "content": "Fixture instruction"],
            ["role": "user", "content": "Approved synthetic input"]
        ])
        XCTAssertNil(json["conversation"])
        XCTAssertNil(json["previous_response_id"])
    }

    func testRedirectIsRejectedBeforeForwardingAnAuthorizationHeader() async throws {
        let base = try XCTUnwrap(AIModelClient.baseURL(from: "https://localhost:19443/v1"))
        let request = try AIModelClient.modelListRequest(baseURL: base, apiKey: "fixture-key")
        let originalURL = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: originalURL, statusCode: 307, httpVersion: nil, headerFields: nil))
        let destination = try XCTUnwrap(URL(string: "https://localhost:19444/v1/models"))
        var redirected = URLRequest(url: destination)
        redirected.setValue("Bearer fixture-key", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        let permitted = await AIModelRedirectHandler().urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: redirected
        )
        XCTAssertNil(permitted)
    }

    func testUnverifiedContextUsesTheShortBudgetAndVerifiedContextIsClamped() throws {
        XCTAssertEqual(AIModelClient.compatibleContextLimit(for: try profile()), 4_096)
        XCTAssertEqual(AIModelClient.compatibleContextLimit(for: try profile(contextLimit: 16_384)), 16_384)
        XCTAssertEqual(AIModelClient.compatibleContextLimit(for: try profile(contextLimit: 300_000)), 256_000)
        let rejection = Data(#"{"error":{"param":"reasoning_effort","message":"Internal fixture detail"}}"#.utf8)
        let error = AIModelClient.rejection(status: 400, body: rejection)
        XCTAssertEqual(error, .unsupportedEffort)
        XCTAssertFalse(error.errorDescription?.contains("Internal fixture detail") ?? false)
        XCTAssertEqual(AIModelClient.rejection(status: 413, body: Data()), .contextLimitExceeded)
    }

    @MainActor
    func testChangedEndpointCannotReadThePreviousCredential() throws {
        let settings = AIModelSettings(inMemory: true)
        let original = try profile()
        try settings.save(original, apiKey: "first-fixture-key")
        XCTAssertEqual(try settings.apiKey(for: original), "first-fixture-key")

        let secondBase = try XCTUnwrap(AIModelClient.baseURL(from: "https://localhost:19444/v1"))
        let updated = AIProviderProfile(baseURL: secondBase, model: original.model, effort: .medium, contextLimit: nil)
        try settings.save(updated, apiKey: "")
        XCTAssertNil(try settings.apiKey(for: updated))
        XCTAssertThrowsError(try settings.apiKey(for: original)) { error in
            XCTAssertEqual(error as? AIModelClientError, .settingsChanged)
        }
    }

    private func profile(effort: AIReasoningEffort = .medium, contextLimit: Int? = nil) throws -> AIProviderProfile {
        let base = try XCTUnwrap(AIModelClient.baseURL(from: "https://localhost:19443/v1"))
        return AIProviderProfile(baseURL: base, model: "fixture-model", effort: effort, contextLimit: contextLimit,
                                 api: .chatCompletions)
    }
}
