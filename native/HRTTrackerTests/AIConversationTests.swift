import HRTEngine
import SwiftData
import XCTest
@testable import HRTTracker

final class AIConversationTests: XCTestCase {
    @MainActor
    func testOneLocalConversationAndMemorySurviveReopening() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = AIChatTurn(date: .now, mode: .transfem, question: "First", answer: "One",
                               sources: [.lab("local-lab")])
        let second = AIChatTurn(date: first.date, mode: .transmasc, question: "Second", answer: "Two",
                                sources: [.dose("local-dose")])
        do {
            let store = AIConversationStore(directory: directory)
            XCTAssertFalse(store.storageUnavailable)
            try store.append(first)
            try store.append(second)
            try store.saveMemory(id: nil, mode: .transfem, text: "Prefer weekly reviews.")
        }
        do {
            let reopened = AIConversationStore(directory: directory)
            XCTAssertFalse(reopened.storageUnavailable)
            XCTAssertEqual(reopened.turns, [first, second])
            let memory = try XCTUnwrap(reopened.memories.first)
            try reopened.saveMemory(id: memory.id, mode: memory.mode, text: "Prefer monthly reviews.")
            XCTAssertEqual(reopened.memories.map(\.id), [memory.id])
            XCTAssertEqual(reopened.memories.first?.text, "Prefer monthly reviews.")
            try reopened.clear()
        }
        let cleared = AIConversationStore(directory: directory)
        XCTAssertTrue(cleared.turns.isEmpty)
        XCTAssertTrue(cleared.memories.isEmpty)
        #if os(iOS)
        let resources = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resources.isExcludedFromBackup, true)
        #endif
    }

    @MainActor
    func testContextCompactionKeepsRawTurnsAndLimitsRemoteContext() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIConversationStore(directory: directory)
        XCTAssertFalse(store.storageUnavailable)
        let older = AIChatTurn(date: .now, mode: .transfem, question: "my-old-question",
                               answer: String(repeating: "private old answer. ", count: 60),
                               sources: [.lab("old-source-id")])
        let recent = AIChatTurn(date: .now, mode: .transfem, question: "my-recent-question",
                                answer: "my-recent-answer", sources: [.dose("recent-source-id")])
        let otherMode = AIChatTurn(date: .now, mode: .transmasc, question: "other-mode-question",
                                   answer: "other-mode-answer", sources: [.lab("other-source-id")])
        for turn in [older, recent, otherMode] { try store.append(turn) }
        try store.saveMemory(id: nil, mode: .transmasc, text: "other-mode-memory")
        try store.saveMemory(id: nil, mode: .transfem, text: "own-mode-memory")

        let local = try store.context(mode: .transfem, modelLimit: 800, reservedTokens: 100,
                                      baseInput: "Question", includeRecentTurns: true)
        XCTAssertTrue(local.recentTurns.contains(recent.question))
        XCTAssertFalse(local.recentTurns.contains(older.question))
        XCTAssertTrue(local.summary.contains(older.question))
        XCTAssertTrue(local.summary.contains("old-source-id"))
        XCTAssertFalse(local.summary.contains("private old answer"))
        XCTAssertTrue(local.longTerm.contains("own-mode-memory"))
        XCTAssertFalse(local.longTerm.contains("other-mode-memory"))
        XCTAssertFalse((local.recentTurns + local.summary).contains("other-mode-question"))
        XCTAssertEqual(store.turns, [older, recent, otherMode])
        try store.append(recent)
        XCTAssertEqual(store.turns, [older, recent, otherMode])

        let reopened = AIConversationStore(directory: directory)
        let restored = try reopened.context(mode: .transfem, modelLimit: 800, reservedTokens: 100,
                                             baseInput: "Question", includeRecentTurns: true)
        XCTAssertEqual(restored.summary, local.summary)
        let remote = try reopened.context(mode: .transfem, modelLimit: 800, reservedTokens: 100,
                                       baseInput: "Question", includeRecentTurns: false)
        XCTAssertTrue(remote.recentTurns.isEmpty)
        XCTAssertFalse(remote.summary.isEmpty)
        XCTAssertFalse(remote.summary.contains(older.question))
        XCTAssertFalse(remote.summary.contains(recent.question))
        XCTAssertFalse(remote.summary.contains("source-id"))
        XCTAssertTrue(remote.longTerm.contains("own-mode-memory"))
        XCTAssertFalse(AIConversationStore.fits(modelLimit: nil, reservedTokens: 100,
                                                baseInput: String(repeating: "a", count: 4_096)))
        try reopened.clear()
        let cleared = try reopened.context(mode: .transfem, modelLimit: 800, reservedTokens: 100,
                                        baseInput: "Question", includeRecentTurns: false)
        XCTAssertTrue(cleared.summary.isEmpty)
        XCTAssertTrue(cleared.longTerm.isEmpty)
    }

    @MainActor
    func testSnapshotUsesMeasuredRecordsWithinTheSelectedRangeAndMode() async throws {
        let schema = TrackerStore.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = TrackerStore(context: container.mainContext, demo: true)
        let now = store.nowH
        XCTAssertTrue(store.saveDoses([
            DoseEvent(route: .oral, timeH: now + 1, doseMG: 6, ester: "CPA"),
            DoseEvent(route: .patchRemove, timeH: now - 1, doseMG: 0, ester: "E2"),
            DoseEvent(route: .oral, timeH: now - 10 * 24, doseMG: 6, ester: "CPA")
        ]))
        XCTAssertTrue(store.saveLab(LabResult(timeH: now + 1, concValue: 82, unit: "pg/ml")))
        XCTAssertTrue(store.saveLab(LabResult(timeH: now - 1, concValue: 82, unit: "ng/dl")))
        let week = await AIInsightSnapshot.capture(store: store, range: .week)
        XCTAssertEqual(week.doses.count, 6)
        XCTAssertEqual(week.labs.count, 2)
        XCTAssertEqual(week.facts.first { $0.id == "latest-lab" }?.source,
                       week.labs.first.map { .lab($0.id) })
        XCTAssertEqual(week.facts.first { $0.id == "estimate-e2" }?.source, .curve)
        let month = await AIInsightSnapshot.capture(store: store, range: .month)
        XCTAssertEqual(month.doses.count, 7)

        store.mode = .transmasc
        let testosterone = await AIInsightSnapshot.capture(store: store, range: .week)
        XCTAssertEqual(testosterone.doses.count, 1)
        XCTAssertEqual(testosterone.labs.first?.unit, "ng/dl")
        XCTAssertTrue(testosterone.facts.contains { $0.id == "estimate-t" })
        XCTAssertFalse(testosterone.facts.contains { $0.id == "estimate-e2" })
    }
}
