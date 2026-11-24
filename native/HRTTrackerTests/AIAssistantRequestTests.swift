import XCTest
@testable import HRTTracker

final class AIAssistantRequestTests: XCTestCase {
    func testReplyCanOnlySelectKnownFactsOrReportOutOfScope() throws {
        let request = makeRequest()
        let selection = try request.selection(from: #"{"status":"answer","factIDs":["fact-2","fact-1"]}"#)
        XCTAssertEqual(selection.facts.map(\.id), ["latest-lab", "dose-count"])
        XCTAssertFalse(selection.outOfScope)
        XCTAssertTrue(try request.selection(from: #"{"status":"out_of_scope","factIDs":[]}"#).outOfScope)

        for invalid in [
            #"{"status":"answer","factIDs":["fact-99"]}"#,
            #"{"status":"answer","factIDs":["fact-1","fact-1"]}"#,
            #"{"status":"answer","factIDs":[]}"#,
            #"{"status":"answer","factIDs":["fact-1"],"advice":"Unexpected text"}"#,
            #"{"status":"out_of_scope","factIDs":["fact-1"]}"#
        ] {
            XCTAssertThrowsError(try request.selection(from: invalid))
        }
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
                report: "Full private report", doses: [], labs: []
            )
        )
    }

    private func payload(_ input: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
    }
}
