import XCTest
@testable import HRTTracker

final class AIAssistantGenerationTests: XCTestCase {
    private enum SimulatedFailure: Error {
        case interrupted
    }

    @MainActor
    private final class StreamCapture {
        var updates: [String] = []
    }

    @MainActor
    func testStopsAtRoleBoundaryAndCompletesWithTheValidPrefix() async throws {
        let capture = StreamCapture()
        let answer = try await AIAssistantReplyGuard.completedReply { update in
            try update("我可以帮你。")
            try update("我可以帮你。\n<|im_st")
            try update("我可以帮你。\n<|im_start|>user")
            XCTFail("A complete role boundary should stop generation")
            return ""
        } onUpdate: { capture.updates.append($0) }

        XCTAssertEqual(answer, "我可以帮你。")
        XCTAssertEqual(capture.updates, ["我可以帮你。", "我可以帮你。\n"])
    }

    @MainActor
    func testInterruptedStreamDiscardsPartialAnswerAndCanBeRetried() async throws {
        let first = StreamCapture()
        do {
            _ = try await AIAssistantReplyGuard.completedReply { update in
                try update("Unfinished answer")
                throw SimulatedFailure.interrupted
            } onUpdate: { first.updates.append($0) }
            XCTFail("An interrupted stream must not return a completed reply")
        } catch SimulatedFailure.interrupted {
            XCTAssertEqual(first.updates, ["Unfinished answer"])
        }

        let retry = StreamCapture()
        let answer = try await AIAssistantReplyGuard.completedReply { update in
            try update("Retried answer")
            return "Retried answer"
        } onUpdate: { retry.updates.append($0) }

        XCTAssertEqual(answer, "Retried answer")
        XCTAssertEqual(retry.updates, ["Retried answer"])
    }

    @MainActor
    func testRejectsProtocolOnlyResponse() async throws {
        let capture = StreamCapture()
        do {
            _ = try await AIAssistantReplyGuard.completedReply { update in
                try update("<|im_start|>assistant")
                return "Unreachable"
            } onUpdate: { capture.updates.append($0) }
            XCTFail("A protocol-only response must not return a completed reply")
        } catch AIOfflineModel.Failure.emptyResponse {
            XCTAssertTrue(capture.updates.isEmpty)
        }
    }

    @MainActor
    func testCancellationDropsLateUpdatesAndTheReturnedAnswer() async throws {
        let capture = StreamCapture()
        let generation = Task {
            try await AIAssistantReplyGuard.completedReply { update in
                try update("Visible before stop")
                withUnsafeCurrentTask { $0?.cancel() }
                try? update("Late update")
                return "Late answer"
            } onUpdate: { capture.updates.append($0) }
        }

        do {
            _ = try await generation.value
            XCTFail("A reply returned after cancellation must be discarded")
        } catch is CancellationError {
            XCTAssertEqual(capture.updates, ["Visible before stop"])
        }
    }
}
