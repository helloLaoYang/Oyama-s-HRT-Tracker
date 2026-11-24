import XCTest
@testable import HRTTracker

final class AIModelConsentTests: XCTestCase {
    @MainActor
    func testLegacySettingsDefaultToResponsesAndRequireNewApproval() throws {
        let suite = "AIModelConsentTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let profile = try provider()
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "baseURL": profile.baseURL.absoluteString,
            "model": profile.model,
            "effort": profile.effort.rawValue
        ]), forKey: "ai.compatibleProvider.v1")
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "baseURL": profile.baseURL.absoluteString,
            "model": profile.model,
            "includeMemory": false
        ]), forKey: "ai.externalSendingApproval.v1")

        let settings = AIModelSettings(defaults: defaults)
        XCTAssertEqual(settings.profile, profile)
        XCTAssertEqual(settings.profile?.api, .responses)
        XCTAssertEqual(settings.profile?.requestsReasoningSummary, false)
        XCTAssertNil(settings.rememberedSending(for: profile))
        XCTAssertNil(settings.rememberedSending(for: profile, includesAttachments: true))
    }

    @MainActor
    func testRememberedSendingPersistsWithTheSelectedMemoryChoice() throws {
        let suite = "AIModelConsentTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let profile = try provider()
        defaults.set(try JSONEncoder().encode(profile), forKey: "ai.compatibleProvider.v1")
        let settings = AIModelSettings(defaults: defaults)
        XCTAssertEqual(settings.confirmationMode, .firstSend)
        XCTAssertNil(settings.rememberedSending(for: profile))
        settings.authorizeSending(for: profile, includeMemory: true, includesAttachments: true)
        XCTAssertNil(settings.rememberedSending(for: profile))
        XCTAssertTrue(settings.hasSendingApproval)
        settings.authorizeSending(for: profile, includeMemory: false)

        let reopened = AIModelSettings(defaults: defaults)
        XCTAssertEqual(reopened.rememberedSending(for: profile), false)
        XCTAssertEqual(reopened.rememberedSending(for: profile, includesAttachments: true), true)
        reopened.setConfirmationMode(.everySend)
        reopened.authorizeSending(for: profile, includeMemory: true)
        reopened.authorizeSending(for: profile, includeMemory: true, includesAttachments: true)
        XCTAssertNil(reopened.rememberedSending(for: profile))
        XCTAssertNil(reopened.rememberedSending(for: profile, includesAttachments: true))

        let everySend = AIModelSettings(defaults: defaults)
        XCTAssertEqual(everySend.confirmationMode, .everySend)
        everySend.setConfirmationMode(.firstSend)
        XCTAssertNil(everySend.rememberedSending(for: profile))
    }

    @MainActor
    func testAuthorizationResetsWhenRecipientOrCredentialChanges() throws {
        let settings = AIModelSettings(inMemory: true)
        let original = try provider()
        try settings.save(original, apiKey: "first-key")
        let approvedRevision = settings.sendingRevision
        settings.authorizeSending(for: original, includeMemory: true)
        XCTAssertEqual(settings.sendingRevision, approvedRevision)

        let expanded = try provider(effort: .high, contextLimit: 16_384)
        try settings.save(expanded, apiKey: "first-key")
        XCTAssertEqual(settings.sendingRevision, approvedRevision)
        XCTAssertEqual(settings.rememberedSending(for: expanded), true)
        XCTAssertNil(settings.rememberedSending(for: original))

        try settings.save(expanded, apiKey: "second-key")
        XCTAssertNotEqual(settings.sendingRevision, approvedRevision)
        XCTAssertNil(settings.rememberedSending(for: expanded))
        settings.authorizeSending(for: expanded, includeMemory: false)

        let otherModel = try provider(model: "other-model")
        try settings.save(otherModel, apiKey: "second-key")
        XCTAssertNil(settings.rememberedSending(for: otherModel))
        settings.authorizeSending(for: otherModel, includeMemory: false)

        let otherEndpoint = try provider(port: 19444, model: "other-model")
        try settings.save(otherEndpoint, apiKey: "second-key")
        XCTAssertNil(settings.rememberedSending(for: otherEndpoint))
        settings.authorizeSending(for: otherEndpoint, includeMemory: true)
        let previousRevision = settings.sendingRevision
        settings.revokeSendingApproval()
        XCTAssertNotEqual(settings.sendingRevision, previousRevision)
        XCTAssertFalse(settings.hasSendingApproval)
        settings.authorizeSending(for: otherEndpoint, includeMemory: true)
        try settings.remove()
        try settings.save(otherEndpoint, apiKey: "second-key")
        XCTAssertNil(settings.rememberedSending(for: otherEndpoint))
    }

    @MainActor
    func testChangingAPIRevokesBothGrantsButChangingSummaryPreservesThem() throws {
        let settings = AIModelSettings(inMemory: true)
        let chat = try provider(api: .chatCompletions)
        try settings.save(chat, apiKey: "fixture-key")
        settings.authorizeSending(for: chat, includeMemory: false)
        settings.authorizeSending(for: chat, includeMemory: true, includesAttachments: true)
        let chatRevision = settings.sendingRevision

        let responses = try provider(api: .responses)
        try settings.save(responses, apiKey: "fixture-key")
        XCTAssertNotEqual(settings.sendingRevision, chatRevision)
        XCTAssertNil(settings.rememberedSending(for: responses))
        XCTAssertNil(settings.rememberedSending(for: responses, includesAttachments: true))

        settings.authorizeSending(for: responses, includeMemory: true)
        settings.authorizeSending(for: responses, includeMemory: false, includesAttachments: true)
        let responsesRevision = settings.sendingRevision
        let withSummary = try provider(api: .responses, requestsReasoningSummary: true)
        try settings.save(withSummary, apiKey: "fixture-key")
        XCTAssertEqual(settings.sendingRevision, responsesRevision)
        XCTAssertEqual(settings.rememberedSending(for: withSummary), true)
        XCTAssertEqual(settings.rememberedSending(for: withSummary, includesAttachments: true), false)
        let profileData = try JSONEncoder().encode(withSummary)
        XCTAssertEqual(try JSONDecoder().decode(AIProviderProfile.self, from: profileData), withSummary)

        settings.revokeSendingApproval()
        XCTAssertNil(settings.rememberedSending(for: withSummary))
        XCTAssertNil(settings.rememberedSending(for: withSummary, includesAttachments: true))
    }

    private func provider(port: Int = 19443, model: String = "fixture-model", effort: AIReasoningEffort = .medium,
                          contextLimit: Int? = nil, api: AIProviderAPI = .responses,
                          requestsReasoningSummary: Bool = false) throws -> AIProviderProfile {
        let url = try XCTUnwrap(URL(string: "https://localhost:\(port)/v1"))
        return AIProviderProfile(baseURL: url, model: model, effort: effort, contextLimit: contextLimit,
                                 api: api, requestsReasoningSummary: requestsReasoningSummary)
    }
}
