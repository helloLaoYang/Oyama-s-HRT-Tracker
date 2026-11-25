import XCTest
@testable import HRTTracker

final class AIAssistantRequestTests: XCTestCase {
    func testGeneralQuestionCanReceiveAnAnswerWithoutRecordFacts() throws {
        let snapshot = AIInsightSnapshot(mode: .transfem, range: .month, facts: [], doses: [], labs: [])
        let question = AIAssistantRequest(purpose: .question, question: "Why is the sky blue?", snapshot: snapshot)
        let answer = "Air scatters blue light more strongly than red light."
        let selection = try question.streamSelection(from: answer)

        XCTAssertEqual(selection.answer, answer)
        XCTAssertTrue(selection.facts.isEmpty)
        XCTAssertThrowsError(try question.streamSelection(from: " "))
        XCTAssertThrowsError(try question.streamSelection(from: question.prompt))
    }

    func testStreamHidesCitationTrailerAndLinksOnlyKnownRecords() throws {
        let request = makeRequest()
        let answer = "The latest record is a lab measurement."
        let partial = answer + "\n\n[[sources: fact-"
        XCTAssertEqual(AIAssistantRequest.displayedStreamText(partial), answer)

        let reply = try request.streamSelection(from: answer + "\n\n[[sources: fact-2, fact-99, fact-2]]")
        XCTAssertEqual(reply.answer, answer)
        XCTAssertEqual(reply.facts.map(\.id), ["latest-lab"])
    }

    func testLocalPromptSeparatesUserMessageAndRoleHistoryFromReferenceData() throws {
        let request = makeRequest()
        let earlier = AIChatTurn(date: .now, mode: .transfem, question: "Earlier question",
                                 answer: "Earlier answer", sources: [])
        let context = AIConversationContext(recentTurns: [earlier], summary: "Saved summary",
                                            longTerm: "Saved preference")
        let base = try referenceData(in: request.instructions(context: nil))
        let instructions = try request.instructions(context: context)
        let onDevice = try referenceData(in: instructions)

        XCTAssertEqual(request.prompt, "What is the latest lab result?")
        XCTAssertFalse(instructions.contains(request.prompt))
        XCTAssertFalse(instructions.contains(earlier.question))
        XCTAssertFalse(instructions.contains(earlier.answer))
        XCTAssertNil(onDevice["question"])
        XCTAssertNil(onDevice["recentTurns"])
        XCTAssertEqual(onDevice["rangeDays"] as? Int, 30)
        XCTAssertNil(base["previousSummary"])
        XCTAssertNil(base["localMemory"])
        XCTAssertEqual(onDevice["previousSummary"] as? String, "Saved summary")
        XCTAssertEqual(onDevice["localMemory"] as? String, "Saved preference")
        let facts = try XCTUnwrap(onDevice["facts"] as? [[String: String]])
        XCTAssertEqual(facts.map { $0["id"] }, ["fact-1", "fact-2"])
        XCTAssertFalse(facts.flatMap(\.values).contains("private-lab-id"))
    }

    private func makeRequest() -> AIAssistantRequest {
        AIAssistantRequest(
            purpose: .question, question: "What is the latest lab result?",
            snapshot: AIInsightSnapshot(
                mode: .transfem, range: .month,
                facts: [
                    AIInsightFact(id: "dose-count", text: "Two recorded doses.", source: nil),
                    AIInsightFact(id: "latest-lab", text: "Latest lab measurement.", source: .lab("private-lab-id"))
                ],
                doses: [], labs: []
            )
        )
    }

    private func referenceData(in instructions: String) throws -> [String: Any] {
        let marker = try XCTUnwrap(instructions.range(of: "\nReference data (JSON):\n"))
        let data = Data(instructions[marker.upperBound...].utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
