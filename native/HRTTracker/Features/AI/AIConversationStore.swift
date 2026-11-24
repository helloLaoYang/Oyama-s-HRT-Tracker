import Foundation
import HRTEngine
import Observation
import SwiftData

struct AIChatTurn: Identifiable, Equatable, Sendable {
    var id = UUID()
    let date: Date
    let mode: HRTMode
    let question: String
    let answer: String
    let sources: [AIRecordReference]
    var document: AIConversationDocument? = nil
    var reasoningSummary: String? = nil
    var generatedImage: Data? = nil
    var attachmentNames: [String] = []
}

struct AIMemoryEntry: Identifiable, Equatable, Sendable {
    var id = UUID()
    let mode: HRTMode
    let text: String
}

struct AIConversationContext {
    let recentTurns: String
    let summary: String
    let longTerm: String
}

enum AIConversationError: LocalizedError {
    case unavailable, memoryTooLong, contextTooLong

    var errorDescription: String? {
        switch self {
        case .unavailable: aiDataLabel("Could not access local AI storage.")
        case .memoryTooLong: aiDataLabel("Enter a memory of 500 characters or fewer.")
        case .contextTooLong: aiDataLabel("This request is too long for the selected model.")
        }
    }
}

@MainActor
@Observable
final class AIConversationStore {
    private(set) var turns: [AIChatTurn] = []
    private(set) var memories: [AIMemoryEntry] = []
    private(set) var storageUnavailable = false

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var nextSequence = 0

    init(inMemory: Bool = false, directory: URL? = nil) {
        do {
            let schema = Schema([AIStoredTurn.self, AIStoredMemory.self, AIStoredCompaction.self])
            let configuration: ModelConfiguration
            if inMemory {
                configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                                   cloudKitDatabase: .none)
            } else {
                let root = try directory ?? FileManager.default
                    .url(for: .applicationSupportDirectory, in: .userDomainMask,
                         appropriateFor: nil, create: true)
                    .appendingPathComponent("HRTraceAI", isDirectory: true)
                try Self.prepareLocalDirectory(root)
                configuration = ModelConfiguration(schema: schema,
                                                   url: root.appendingPathComponent("Conversation.store"),
                                                   cloudKitDatabase: .none)
            }
            let loaded = try ModelContainer(for: schema, configurations: configuration)
            loaded.mainContext.autosaveEnabled = false
            let records = try loaded.mainContext.fetch(FetchDescriptor<AIStoredTurn>(
                sortBy: [SortDescriptor(\.sequence)]))
            turns = records.compactMap(\.turn)
            nextSequence = (records.last?.sequence ?? -1) + 1
            memories = try loaded.mainContext.fetch(FetchDescriptor<AIStoredMemory>(
                sortBy: [SortDescriptor(\.updated, order: .reverse)])).compactMap(\.entry)
            container = loaded
        } catch {
            turns = []
            memories = []
            storageUnavailable = true
        }
    }

    private static func prepareLocalDirectory(_ url: URL) throws {
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: attributes)
        var directory = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    func append(_ turn: AIChatTurn) throws {
        guard !turns.contains(where: { $0.id == turn.id }) else { return }
        let sources = try JSONEncoder().encode(turn.sources)
        let document = try turn.document.map { try JSONEncoder().encode($0) }
        let media = try AIConversationMedia(turn).map { try JSONEncoder().encode($0) }
        try write { context in
            context.insert(AIStoredTurn(turn: turn, sequence: nextSequence, sources: sources,
                                        documentData: document, mediaData: media))
        }
        nextSequence += 1
        turns.append(turn)
    }

    func updateDocument(_ id: UUID, text: String) throws {
        guard let index = turns.firstIndex(where: { $0.id == id }), var document = turns[index].document,
              document.kind == .visit else { throw AIConversationError.unavailable }
        document.editedText = text == document.generatedText ? nil : text
        let data = try JSONEncoder().encode(document)
        try write { context in
            var request = FetchDescriptor<AIStoredTurn>(predicate: #Predicate { $0.id == id })
            request.fetchLimit = 1
            guard let record = try context.fetch(request).first else { throw AIConversationError.unavailable }
            record.documentData = data
        }
        let current = turns[index]
        turns[index] = AIChatTurn(id: current.id, date: current.date, mode: current.mode,
                                  question: current.question, answer: document.exportText,
                                  sources: current.sources, document: document,
                                  reasoningSummary: current.reasoningSummary, generatedImage: current.generatedImage,
                                  attachmentNames: current.attachmentNames)
    }

    func saveMemory(id: UUID?, mode: HRTMode, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { throw AIConversationError.memoryTooLong }
        let entry = AIMemoryEntry(id: id ?? UUID(), mode: mode, text: trimmed)
        try write { context in
            if let id {
                guard let record = try memoryRecord(id, in: context), record.mode == mode.rawValue
                else { throw AIConversationError.unavailable }
                record.text = trimmed
                record.updated = .now
            } else {
                context.insert(AIStoredMemory(entry))
            }
        }
        memories.removeAll { $0.id == entry.id }
        memories.insert(entry, at: 0)
    }

    func deleteMemory(_ id: UUID) throws {
        try write { context in
            if let record = try memoryRecord(id, in: context) { context.delete(record) }
        }
        memories.removeAll { $0.id == id }
    }

    func clear() throws {
        try write { context in
            for record in try context.fetch(FetchDescriptor<AIStoredTurn>()) { context.delete(record) }
            for record in try context.fetch(FetchDescriptor<AIStoredMemory>()) { context.delete(record) }
            for record in try context.fetch(FetchDescriptor<AIStoredCompaction>()) { context.delete(record) }
        }
        turns = []
        memories = []
        nextSequence = 0
    }

    func context(mode: HRTMode, modelLimit: Int?, reservedTokens: Int, baseInput: String,
                 includeRecentTurns: Bool) throws -> AIConversationContext {
        let inputLimit = Self.inputLimit(modelLimit: modelLimit, reservedTokens: reservedTokens)
        let baseCost = Self.estimatedCost(baseInput) + 32
        guard baseCost < inputLimit else { throw AIConversationError.contextTooLong }

        let available = inputLimit - baseCost
        let remembered = boundedMemory(for: mode, budget: min(2_048, available / 3))
        let modeTurns = turns.filter { $0.mode == mode && $0.document == nil }
        let stored = try checkpoint(for: mode)
        let boundary = stored.flatMap { digest in
            modeTurns.firstIndex { $0.id == digest.through }.map { $0 + 1 }
        } ?? 0
        var digest = boundary > 0 ? stored?.digest ?? AIConversationDigest() : AIConversationDigest()
        let remainder = modeTurns.dropFirst(boundary)
        let workingBudget = max(0, min(available, inputLimit * 4 / 5 - baseCost) - Self.estimatedCost(remembered))
        let previousSummaryCost = Self.estimatedCost(digest.text(withDetails: includeRecentTurns))
        let rawBudget = max(0, workingBudget - previousSummaryCost)
        var recentCount = Self.newestFittingCount(remainder, budget: rawBudget)
        if recentCount < remainder.count {
            let summaryReserve = max(previousSummaryCost, min(512, workingBudget / 4))
            recentCount = Self.newestFittingCount(remainder, budget: max(0, workingBudget - summaryReserve))
            let older = remainder.dropLast(recentCount)
            digest.include(older)
            if let last = older.last { try saveCheckpoint(mode: mode, through: last.id, digest: digest) }
        }

        let recent = remainder.suffix(recentCount)
        // External previews include topic labels and explicit memories. Question snippets,
        // internal source identifiers and raw transcript turns remain on this device.
        if !includeRecentTurns { digest.include(recent) }
        let recentText = includeRecentTurns ? recent.map(Self.transcript).joined(separator: "\n\n") : ""
        let summaryBudget = available - Self.estimatedCost(recentText) - Self.estimatedCost(remembered)
        var summary = digest.text(withDetails: includeRecentTurns)
        if Self.estimatedCost(summary) > summaryBudget { summary = digest.text(withDetails: false) }
        if Self.estimatedCost(summary) > summaryBudget { summary = "" }
        return AIConversationContext(recentTurns: recentText, summary: summary, longTerm: remembered)
    }

    static func fits(modelLimit: Int?, reservedTokens: Int, baseInput: String) -> Bool {
        estimatedCost(baseInput) + 32 < inputLimit(modelLimit: modelLimit, reservedTokens: reservedTokens)
    }

    private static func inputLimit(modelLimit: Int?, reservedTokens: Int) -> Int {
        let limit = min(AIModelClient.defaultContextLimit, modelLimit ?? AIModelClient.unverifiedContextLimit)
        return limit - min(max(0, reservedTokens), max(0, limit))
    }

    private static func estimatedCost(_ text: String) -> Int {
        // Include JSON escapes without depending on a particular provider's tokenizer.
        text.utf8.reduce(0) { count, byte in
            switch byte {
            case 8, 9, 10, 12, 13, 34, 47, 92: count + 2
            case 0...31: count + 6
            default: count + 1
            }
        }
    }

    private static func transcript(_ turn: AIChatTurn) -> String {
        "User: \(turn.question)\nAssistant: \(turn.answer)"
    }

    private static func newestFittingCount(_ turns: ArraySlice<AIChatTurn>, budget: Int) -> Int {
        var remaining = budget
        var count = 0
        for turn in turns.reversed() {
            let cost = estimatedCost(turn.question) + estimatedCost(turn.answer) + 20
            if cost > remaining { break }
            remaining -= cost
            count += 1
        }
        return count
    }

    private func boundedMemory(for mode: HRTMode, budget: Int) -> String {
        var remaining = budget
        var lines: [String] = []
        for entry in memories where entry.mode == mode {
            let cost = Self.estimatedCost(entry.text) + 3
            if cost <= remaining {
                lines.append("- " + entry.text)
                remaining -= cost
            }
        }
        return lines.joined(separator: "\n")
    }

    private func memoryRecord(_ id: UUID, in context: ModelContext) throws -> AIStoredMemory? {
        var request = FetchDescriptor<AIStoredMemory>(predicate: #Predicate { $0.id == id })
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func checkpoint(for mode: HRTMode) throws -> (through: UUID, digest: AIConversationDigest)? {
        guard let context = container?.mainContext else { throw AIConversationError.unavailable }
        do {
            guard let record = try checkpointRecord(mode, in: context) else { return nil }
            return (record.through, try JSONDecoder().decode(AIConversationDigest.self, from: record.data))
        } catch {
            throw AIConversationError.unavailable
        }
    }

    private func saveCheckpoint(mode: HRTMode, through: UUID, digest: AIConversationDigest) throws {
        let data = try JSONEncoder().encode(digest)
        try write { context in
            if let record = try checkpointRecord(mode, in: context) {
                record.through = through
                record.data = data
            } else {
                context.insert(AIStoredCompaction(mode: mode.rawValue, through: through, data: data))
            }
        }
    }

    private func checkpointRecord(_ mode: HRTMode, in context: ModelContext) throws -> AIStoredCompaction? {
        let raw = mode.rawValue
        var request = FetchDescriptor<AIStoredCompaction>(predicate: #Predicate { $0.mode == raw })
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func write(_ body: (ModelContext) throws -> Void) throws {
        guard let context = container?.mainContext else { throw AIConversationError.unavailable }
        do {
            try body(context)
            try context.save()
        } catch {
            context.rollback()
            throw AIConversationError.unavailable
        }
    }
}

@Model
private final class AIStoredTurn {
    @Attribute(.unique) var id: UUID
    var sequence: Int
    var date: Date
    var mode: String
    var question: String
    var answer: String
    var sources: Data
    var documentData: Data? = nil
    @Attribute(.externalStorage) var mediaData: Data? = nil

    init(turn: AIChatTurn, sequence: Int, sources: Data, documentData: Data?, mediaData: Data?) {
        id = turn.id
        self.sequence = sequence
        date = turn.date
        mode = turn.mode.rawValue
        question = turn.question
        answer = documentData == nil ? turn.answer : ""
        self.sources = sources
        self.documentData = documentData
        self.mediaData = mediaData
    }

    var turn: AIChatTurn? {
        guard let mode = HRTMode(rawValue: mode) else { return nil }
        let references = (try? JSONDecoder().decode([AIRecordReference].self, from: sources)) ?? []
        let media = mediaData.flatMap { try? JSONDecoder().decode(AIConversationMedia.self, from: $0) }
        let document: AIConversationDocument?
        if let documentData {
            guard let decoded = try? JSONDecoder().decode(AIConversationDocument.self, from: documentData) else { return nil }
            document = decoded
        } else {
            document = nil
        }
        return AIChatTurn(id: id, date: date, mode: mode, question: question,
                          answer: document?.exportText ?? answer, sources: references, document: document,
                          reasoningSummary: media?.reasoningSummary, generatedImage: media?.generatedImage,
                          attachmentNames: media?.attachmentNames ?? [])
    }
}

private struct AIConversationMedia: Codable {
    let reasoningSummary: String?
    let generatedImage: Data?
    let attachmentNames: [String]

    init?(_ turn: AIChatTurn) {
        guard turn.reasoningSummary != nil || turn.generatedImage != nil || !turn.attachmentNames.isEmpty else { return nil }
        reasoningSummary = turn.reasoningSummary
        generatedImage = turn.generatedImage
        attachmentNames = turn.attachmentNames
    }
}

@Model
private final class AIStoredMemory {
    @Attribute(.unique) var id: UUID
    var mode: String
    var text: String
    var updated: Date

    init(_ entry: AIMemoryEntry) {
        id = entry.id
        mode = entry.mode.rawValue
        text = entry.text
        updated = .now
    }

    var entry: AIMemoryEntry? {
        HRTMode(rawValue: mode).map { AIMemoryEntry(id: id, mode: $0, text: text) }
    }
}

@Model
private final class AIStoredCompaction {
    @Attribute(.unique) var mode: String
    var through: UUID
    var data: Data

    init(mode: String, through: UUID, data: Data) {
        self.mode = mode
        self.through = through
        self.data = data
    }
}

private struct AIConversationDigest: Codable {
    enum Topic: String, CaseIterable, Codable {
        case medication, labs, estimates, review

        var title: String {
            switch self {
            case .medication: aiDataLabel("medication records")
            case .labs: aiDataLabel("lab results")
            case .estimates: aiDataLabel("model estimates")
            case .review: aiDataLabel("record review")
            }
        }
    }

    private struct Detail: Codable {
        let question: String
        let sources: [AIRecordReference]
    }

    private var topics: Set<Topic> = []
    private var details: [Detail] = []

    mutating func include(_ turns: ArraySlice<AIChatTurn>) {
        for turn in turns {
            if turn.sources.isEmpty { topics.insert(.review) }
            for source in turn.sources {
                switch source {
                case .dose: topics.insert(.medication)
                case .lab: topics.insert(.labs)
                case .curve: topics.insert(.estimates)
                }
            }
            let line = turn.question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let excerpt = String(line.prefix(96)) + (line.count > 96 ? "…" : "")
            details = Array((details + [Detail(question: excerpt, sources: Array(turn.sources.prefix(2)))]).suffix(3))
        }
    }

    func text(withDetails: Bool) -> String {
        guard !topics.isEmpty else { return "" }
        let names = Topic.allCases.filter(topics.contains).map(\.title).joined(separator: ", ")
        let heading = aiDataLabel("Earlier discussion topics: \(names)")
        guard withDetails else { return heading }
        let notes = details.map { detail in
            let sources = detail.sources.map(\.historicalIdentifier).joined(separator: ", ")
            return detail.question + (sources.isEmpty ? "" : " [\(sources)]")
        }.joined(separator: "\n")
        return [heading, aiDataLabel("Earlier questions and source references:"), notes].joined(separator: "\n")
    }
}

private extension AIRecordReference {
    var historicalIdentifier: String {
        switch self {
        case .dose(let id): "dose:\(id)"
        case .lab(let id): "lab:\(id)"
        case .curve: "curve"
        }
    }
}

func aiDataLabel(_ key: String.LocalizationValue) -> String {
    label(key, table: "AIData")
}
