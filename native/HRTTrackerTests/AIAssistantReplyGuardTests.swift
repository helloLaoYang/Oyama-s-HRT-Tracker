import XCTest
@testable import HRTTracker

final class AIAssistantReplyGuardTests: XCTestCase {
    func testTranscriptLoopIsStoppedBeforeDisplayAndCannotBeReplayed() throws {
        for snapshot in ["U", "Us", "User", "User "] {
            XCTAssertEqual(try AIAssistantReplyGuard.streamText(snapshot), "")
        }
        let echoed = """
        User: 你是谁
        Assistant: User: 如果是预计呢
        Assistant: User: 你是谁
        """
        assertStop(echoed, prefix: "")
        XCTAssertNil(AIAssistantReplyGuard.finalText(echoed))
        XCTAssertNil(AIAssistantReplyGuard.finalText("  助手：用户：你是谁"))
    }

    func testAValidAnswerAndCitationSurviveFollowingRoleText() throws {
        let prefix = "我可以帮你回顾化验记录。\n[[sources: fact-1]]\n"
        XCTAssertEqual(try AIAssistantReplyGuard.streamText(prefix + "Assis"), prefix)
        assertStop(prefix + "Assistant: User: 你是谁", prefix: prefix)
        XCTAssertEqual(
            AIAssistantReplyGuard.finalText(prefix + "Assistant: User: 你是谁"),
            "我可以帮你回顾化验记录。\n[[sources: fact-1]]"
        )
    }

    func testLiteralQuotedLabelsAndRegularProseSurvive() throws {
        let answer = """
        Assistant settings are available.
        > User: this is a quotation.
        ```text
        User: 你好
        Assistant: 你好
        ```
        In prose, User: is just a label.
        """
        XCTAssertEqual(try AIAssistantReplyGuard.streamText(answer), answer)
        XCTAssertEqual(AIAssistantReplyGuard.finalText(answer), answer)
        XCTAssertEqual(try AIAssistantReplyGuard.streamText("用户可以查看记录。"), "用户可以查看记录。")
    }

    private func assertStop(_ response: String, prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AIAssistantReplyGuard.streamText(response), file: file, line: line) { error in
            guard case let .roleBoundary(actual)? = error as? AIAssistantReplyGuard.StreamStop else {
                return XCTFail("Expected a role boundary", file: file, line: line)
            }
            XCTAssertEqual(actual, prefix, file: file, line: line)
        }
    }
}
