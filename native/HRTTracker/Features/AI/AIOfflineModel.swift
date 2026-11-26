import Foundation

#if os(iOS) && !targetEnvironment(simulator) && canImport(CoreAI) && canImport(CoreAILanguageModels)
import CoreAILanguageModels
import Darwin
import FoundationModels
#endif

actor AIOfflineModel {
    static let shared = AIOfflineModel()
    static let modelDirectoryName = "Qwen3-8B-abliterated"
    static let modelID = "huihui-ai/" + modelDirectoryName
    static let contextLimit = 4_096
    static let outputLimit = 768

    struct Metrics: Sendable {
        let generatedTokens: Int
        let modelLoadSeconds: Double
        let latencyToFirstTextSeconds: Double
        let generationSeconds: Double
        let totalSeconds: Double
        let baselineMemoryBytes: UInt64?
        let peakMemoryBytes: UInt64?

        var tokensPerSecond: Double {
            generationSeconds > 0 ? Double(generatedTokens) / generationSeconds : 0
        }
    }

    struct Result: Sendable {
        let text: String
        let metrics: Metrics
    }

    enum Failure: LocalizedError {
        case unavailable, missingResources, busy, emptyResponse

        var errorDescription: String? {
            switch self {
            case .unavailable:
                AIModelText.localized("The offline model is unavailable on this device.")
            case .missingResources:
                AIModelText.localized("The offline model files are missing or incomplete.")
            case .busy:
                AIModelText.localized("The offline model is already generating a reply.")
            case .emptyResponse:
                AIModelText.localized("The offline model returned an empty reply.")
            }
        }
    }

    static var isSupported: Bool {
        #if os(iOS) && !targetEnvironment(simulator) && canImport(CoreAI) && canImport(CoreAILanguageModels)
        if #available(iOS 27, *) { return true }
        #endif
        return false
    }

    static var resourcesURL: URL? {
        guard let url = Bundle.main.resourceURL?.appending(path: modelDirectoryName, directoryHint: .isDirectory),
              hasLocalResources(at: url) else { return nil }
        return url
    }

    static func hasLocalResources(at url: URL) -> Bool {
        let manager = FileManager.default
        let metadataURL = url.appending(path: "metadata.json")
        let tokenizerURL = url.appending(path: "tokenizer", directoryHint: .isDirectory)
        guard let data = try? Data(contentsOf: metadataURL),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data),
              manifest.kind == "llm", manifest.source.modelID == modelID,
              manifest.language.embeddedTokenizer,
              manifest.assets.main == URL(fileURLWithPath: manifest.assets.main).lastPathComponent,
              manager.fileExists(atPath: url.appending(path: manifest.assets.main).path),
              manager.fileExists(atPath: tokenizerURL.appending(path: "tokenizer.json").path),
              manager.fileExists(atPath: tokenizerURL.appending(path: "tokenizer_config.json").path)
        else { return false }
        return true
    }

    private struct ModelManifest: Decodable {
        let kind: String
        let assets: Assets
        let language: Language
        let source: Source

        struct Assets: Decodable { let main: String }

        struct Language: Decodable {
            let embeddedTokenizer: Bool

            enum CodingKeys: String, CodingKey {
                case embeddedTokenizer = "embedded_tokenizer"
            }
        }

        struct Source: Decodable {
            let modelID: String

            enum CodingKeys: String, CodingKey {
                case modelID = "hf_model_id"
            }
        }
    }

    #if os(iOS) && !targetEnvironment(simulator) && canImport(CoreAI) && canImport(CoreAILanguageModels)
    private var cachedModel: CoreAILanguageModel?
    private var loadingModel: Task<CoreAILanguageModel, Error>?
    private var isGenerating = false
    #endif

    func prepare() async throws {
        #if os(iOS) && !targetEnvironment(simulator) && canImport(CoreAI) && canImport(CoreAILanguageModels)
        if #available(iOS 27, *) {
            _ = try await loadModel()
            return
        }
        #endif
        throw Failure.unavailable
    }

    func generate(prompt: String, recentTurns: [AIChatTurn],
                  onUpdate: @MainActor @Sendable (String) throws -> Void = { _ in }) async throws -> Result {
        #if os(iOS) && !targetEnvironment(simulator) && canImport(CoreAI) && canImport(CoreAILanguageModels)
        if #available(iOS 27, *) {
            return try await generateUsingCoreAI(prompt: prompt, recentTurns: recentTurns, onUpdate: onUpdate)
        }
        #endif
        throw Failure.unavailable
    }

    #if os(iOS) && !targetEnvironment(simulator) && canImport(CoreAI) && canImport(CoreAILanguageModels)
    @available(iOS 27, *)
    private func loadModel() async throws -> CoreAILanguageModel {
        if let cachedModel { return cachedModel }
        if let loadingModel { return try await loadingModel.value }
        guard let url = Self.resourcesURL else { throw Failure.missingResources }

        // An embedded tokenizer prevents Core AI from fetching one from the Hub.
        let task = Task { try await CoreAILanguageModel(resourcesAt: url, mode: .eager) }
        loadingModel = task
        defer { loadingModel = nil }
        let model = try await task.value
        cachedModel = model
        return model
    }

    @available(iOS 27, *)
    private func generateUsingCoreAI(prompt: String, recentTurns: [AIChatTurn],
                                     onUpdate: @MainActor @Sendable (String) throws -> Void) async throws -> Result {
        guard !isGenerating else { throw Failure.busy }
        isGenerating = true
        defer { isGenerating = false }

        let baseline = Self.memoryFootprint()
        let monitor = Task.detached(priority: .utility) { await Self.sampleMemory(initial: baseline) }
        defer { monitor.cancel() }

        let start = ContinuousClock.now
        let wasPrepared = cachedModel != nil
        let model = try await loadModel()
        try Task.checkCancellation()
        let loadSeconds = wasPrepared ? 0 : Self.seconds(from: start, to: .now)

        var entries: [Transcript.Entry] = []
        for turn in recentTurns {
            entries.append(.prompt(.init(segments: [.text(.init(content: turn.question))])))
            entries.append(.response(.init(metadata: [:], segments: [.text(.init(content: turn.answer))])))
        }
        let session = LanguageModelSession(model: model, tools: [], transcript: Transcript(entries: entries))
        let generationStart = ContinuousClock.now
        let stream = session.streamResponse(
            to: Prompt(prompt),
            options: GenerationOptions(
                samplingMode: .random(probabilityThreshold: 0.95),
                temperature: 0.6,
                maximumResponseTokens: Self.outputLimit
            )
        )
        var firstText: ContinuousClock.Instant?
        var answer = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            let text = snapshot.content
            guard text != answer else { continue }
            if firstText == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                firstText = .now
            }
            answer = text
            try await onUpdate(text)
        }
        try Task.checkCancellation()
        guard let firstText else { throw Failure.emptyResponse }

        let end = ContinuousClock.now
        let generatedTokens = session.usage.output.totalTokenCount
        monitor.cancel()
        return Result(
            text: answer,
            metrics: Metrics(
                generatedTokens: generatedTokens,
                modelLoadSeconds: loadSeconds,
                latencyToFirstTextSeconds: Self.seconds(from: start, to: firstText),
                generationSeconds: Self.seconds(from: generationStart, to: end),
                totalSeconds: Self.seconds(from: start, to: end),
                baselineMemoryBytes: baseline,
                peakMemoryBytes: await monitor.value
            )
        )
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func sampleMemory(initial: UInt64?) async -> UInt64? {
        var peak = initial
        while !Task.isCancelled {
            if let sample = memoryFootprint() { peak = max(peak ?? 0, sample) }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                break
            }
        }
        if let sample = memoryFootprint() { peak = max(peak ?? 0, sample) }
        return peak
    }

    private static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }
    #endif
}
