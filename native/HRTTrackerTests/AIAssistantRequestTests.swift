import XCTest
@testable import HRTTracker

final class AIAssistantRequestTests: XCTestCase {
    func testRecordReplyPreservesGenerativeAnswerAndLinksToKnownFacts() throws {
        let request = makeRequest()
        let selection = try request.selection(from: """
            ```json
            {"answer":"There were two doses and one recent lab result.","factIDs":["fact-2","fact-1"]}
            ```
            """)
        XCTAssertEqual(selection.answer, "There were two doses and one recent lab result.")
        XCTAssertEqual(selection.facts.map(\.id), ["latest-lab", "dose-count"])
    }

    func testHRTEducationCanReceiveAnAnswerWithoutRecordFacts() throws {
        let snapshot = AIInsightSnapshot(mode: .transfem, range: .month, facts: [], doses: [], labs: [])
        let question = AIAssistantRequest(purpose: .question, question: "What does HRT stand for?", snapshot: snapshot)
        let answer = "HRT stands for hormone replacement therapy."
        let selection = try question.selection(from: #"{"answer":"HRT stands for hormone replacement therapy.","factIDs":[]}"#)

        XCTAssertEqual(selection.answer, answer)
        XCTAssertTrue(selection.facts.isEmpty)
    }

    func testReplyRejectsUnrecognizedAndDuplicateFactIDs() {
        let request = makeRequest()
        for invalid in [
            #"{"answer":"Model reply.","factIDs":["fact-99"]}"#,
            #"{"answer":"Model reply.","factIDs":["fact-1","fact-1"]}"#,
            #"{"answer":" ","factIDs":[]}"#,
            #"{"answer":"Model reply.","factIDs":["fact-1"],"advice":"Unexpected text"}"#
        ] {
            XCTAssertThrowsError(try request.selection(from: invalid))
            XCTAssertThrowsError(try request.selection(from: invalid, allowPlainText: true))
        }
    }

    func testCompatibleReplyCanUsePlainTextWithoutClaimingSources() throws {
        let request = makeRequest()
        let text = "Hello! How can I help?"
        XCTAssertThrowsError(try request.selection(from: text))
        let reply = try request.selection(from: text, allowPlainText: true)
        XCTAssertEqual(reply.answer, text)
        XCTAssertTrue(reply.facts.isEmpty)

        let malformed = #"{"answer":"Truncated reply","factIDs":["fact-1""#
        XCTAssertThrowsError(try request.selection(from: malformed, allowPlainText: true))
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

    func testImageRequestOmitsPersonalRecordFacts() throws {
        var request = makeRequest()
        request.includesRecordFacts = false
        let input = try payload(request.input(context: nil, includeRecentTurns: false))
        XCTAssertEqual(input["facts"] as? [[String: String]], [])
        XCTAssertNil(input["localMemory"])
    }

    func testRecordChangeContextUsesLocalDateAndOpaqueFactAliases() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var snapshot = makeRequest().snapshot
        snapshot.capturedInterval = now...now
        snapshot.capturedTimeZoneID = "Asia/Shanghai"
        let request = AIAssistantRequest(purpose: .question, question: "Correct yesterday's result", snapshot: snapshot)

        let input = try payload(request.input(context: nil, includeRecentTurns: false, allowsRecordChanges: true))
        let recordContext = try XCTUnwrap(input["recordContext"] as? [String: String])
        XCTAssertEqual(recordContext["timeZone"], "Asia/Shanghai")
        XCTAssertEqual(recordContext["labAnalyte"], "estradiol")
        XCTAssertTrue(try XCTUnwrap(recordContext["localTime"]).hasSuffix("+08:00"))
        XCTAssertEqual(request.recordReference(for: "fact-2"), .lab("private-lab-id"))
        XCTAssertNil(request.recordReference(for: "fact-1"))
        XCTAssertNil(request.recordReference(for: "private-lab-id"))
        let regularInput = try payload(request.input(context: nil, includeRecentTurns: false))
        XCTAssertNil(regularInput["recordContext"])
    }

    func testExternalPayloadOmitsRawTranscriptAndRecordIDsEvenWithMemoryOptIn() throws {
        let request = makeRequest()
        let context = AIConversationContext(recentTurns: "private transcript", summary: "Saved summary", longTerm: "Saved preference")
        let withoutMemory = try payload(request.input(context: nil, includeRecentTurns: false))
        let withMemory = try payload(request.input(context: context, includeRecentTurns: false))
        let onDevice = try payload(request.input(context: context, includeRecentTurns: true))

        XCTAssertEqual(withoutMemory["question"] as? String, "What is the latest lab result?")
        XCTAssertEqual(withoutMemory["rangeDays"] as? Int, 30)
        XCTAssertNil(withoutMemory["previousSummary"])
        XCTAssertNil(withoutMemory["localMemory"])
        XCTAssertNil(withMemory["recentTurns"])
        XCTAssertEqual(withMemory["previousSummary"] as? String, "Saved summary")
        XCTAssertEqual(withMemory["localMemory"] as? String, "Saved preference")
        XCTAssertEqual(onDevice["recentTurns"] as? String, "private transcript")
        let facts = try XCTUnwrap(withMemory["facts"] as? [[String: String]])
        XCTAssertEqual(facts.map { $0["id"] }, ["fact-1", "fact-2"])
        XCTAssertFalse(facts.flatMap(\.values).contains("private-lab-id"))
        XCTAssertNil(withMemory["report"])
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

    private func payload(_ input: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
    }
}
