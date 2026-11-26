import Foundation

struct AIAssistantRequest: Identifiable {
    private struct RecordContext: Encodable {
        let rangeDays: Int
        let facts: [String]
    }

    private struct ReferenceData: Encodable {
        let records: RecordContext?
        let previousSummary: String?
        let localMemory: String?
    }

    let id = UUID()
    let question: String
    let snapshot: AIInsightSnapshot
    private let records: RecordContext?
    private let facts: [AIInsightFact]

    init(question: String, snapshot: AIInsightSnapshot, includesRecords: Bool = false) {
        self.question = question
        self.snapshot = snapshot
        facts = includesRecords ? Array(snapshot.facts(matching: question).prefix(16)) : []
        records = includesRecords ? RecordContext(rangeDays: snapshot.range.rawValue, facts: facts.map(\.text)) : nil
    }

    var recordSources: [AIRecordReference] {
        var sources: [AIRecordReference] = []
        for source in facts.compactMap(\.source) where !sources.contains(source) {
            sources.append(source)
        }
        return sources
    }

    func modelPrompt(context: AIConversationContext?) throws -> String {
        let summary = context.flatMap { Self.nonempty($0.summary) }
        let memory = context.flatMap { Self.nonempty($0.longTerm) }
        guard records != nil || summary != nil || memory != nil else { return question }

        let reference = ReferenceData(
            records: records,
            previousSummary: summary,
            localMemory: memory
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = String(decoding: try encoder.encode(reference), as: UTF8.self)
        return "Reference data (JSON):\n" + data + "\n\nCurrent message:\n" + question
    }

    private static func nonempty(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}

enum AIModelText {
    static func localized(_ key: String.LocalizationValue) -> String {
        label(key, table: "AIModels")
    }
}
