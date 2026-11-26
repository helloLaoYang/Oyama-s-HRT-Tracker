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

    func testQwenProtocolMarkersStayHiddenAsTheStreamCompletesThem() throws {
        let answer = "Je peux résumer tes résultats."
        let prefix = answer + "\r\n"
        for partial in ["<", "<|", "<|im_", "<|im_st"] {
            XCTAssertEqual(try AIAssistantReplyGuard.streamText(prefix + "\t" + partial), prefix, partial)
        }
        for marker in ["<|im_start|>user", "<|im_end|>", "<|endoftext|>"] {
            let response = prefix + "\t" + marker
            assertStop(response, prefix: prefix)
            XCTAssertEqual(AIAssistantReplyGuard.finalText(response), answer)
        }
        XCTAssertEqual(try AIAssistantReplyGuard.streamText(prefix + "< 10"), prefix + "< 10")
    }

    func testLongTildeFencePreservesProtocolExamplesUntilItCloses() throws {
        let example = """
        形式の例です。
        ~~~~text
        <|im_start|>user
        ~~~
        Utilisateur : une ligne de code
        ~~~~
        """
        let prefix = example + "\n"
        let answer = prefix + "アシスタント設定を開けます。"

        XCTAssertEqual(try AIAssistantReplyGuard.streamText(example), example)
        XCTAssertEqual(try AIAssistantReplyGuard.streamText(prefix + "アシスタ"), prefix)
        XCTAssertEqual(try AIAssistantReplyGuard.streamText(answer), answer)
        assertStop(prefix + "アシスタント：別の質問", prefix: prefix)
        XCTAssertEqual(AIAssistantReplyGuard.finalText(prefix + "アシスタント：別の質問"), example)
    }

    func testBlankFinalResponseIsUnavailable() throws {
        let whitespace = " \t\n\u{3000}"

        XCTAssertEqual(try AIAssistantReplyGuard.streamText(whitespace), whitespace)
        XCTAssertNil(AIAssistantReplyGuard.finalText(whitespace))
    }

    func testFinalResponseDistinguishesIncompleteProtocolMarkersFromOrdinaryWords() {
        let answer = "I can summarize your records."

        XCTAssertEqual(AIAssistantReplyGuard.finalText(answer + "\n  <|im_sta"), answer)
        XCTAssertNil(AIAssistantReplyGuard.finalText("<|endof"))
        XCTAssertEqual(AIAssistantReplyGuard.finalText("Answer\n  <|im_sta  \n"), "Answer")
        XCTAssertEqual(AIAssistantReplyGuard.finalText(answer + "\nassistant"), answer + "\nassistant")
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
