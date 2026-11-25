import HRTEngine
import SwiftUI

@MainActor
struct AIAssistantView: View {
    typealias ReplyUpdate = @MainActor @Sendable (String) throws -> Void
    typealias GenerateReply = @Sendable (String, String, [AIChatTurn], ReplyUpdate) async throws -> String

    let store: TrackerStore
    let conversation: AIConversationStore
    let showCurve: () -> Void
    private let generateReply: GenerateReply

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isQuestionFocused: Bool

    @State private var range: AIRange = .month
    @State private var loadedSnapshot: AIInsightSnapshot?
    @State private var loadedKey: SnapshotKey?
    @State private var question = ""
    @State private var liveReply: LiveReply?
    @State private var presentedReport: ReportRoute?
    @State private var sheet: RecordDetail?
    @State private var requestTask: Task<Void, Never>?
    @State private var runningID: UUID?
    @State private var failure: Failure?
    @State private var showClearConfirmation = false

    init(
        store: TrackerStore, conversation: AIConversationStore,
        generateReply: @escaping GenerateReply = { instructions, prompt, recentTurns, onUpdate in
            try await AIOfflineModel.shared.generate(
                instructions: instructions, prompt: prompt, recentTurns: recentTurns, onUpdate: onUpdate
            ).text
        },
        showCurve: @escaping () -> Void
    ) {
        self.store = store
        self.conversation = conversation
        self.generateReply = generateReply
        self.showCurve = showCurve
    }

    private struct Failure {
        let message: String
        var canRetry = false
    }

    private struct ReportRoute: Hashable {
        let id = UUID()
        let document: AIConversationDocument
        let mode: HRTMode
        let savedTurnID: UUID?

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private struct SnapshotKey: Equatable {
        let mode: HRTMode
        let range: AIRange
        let day: Date
        let doses: [DoseEvent]
        let labs: [LabResult]
    }

    private struct LiveReply {
        let question: String
        var text = ""

        var scrollStep: Int { text.utf8.count / 64 }
    }

    private struct RecordDetail: Identifiable {
        let reference: AIRecordReference

        var id: String {
            switch reference {
            case .dose(let id): "dose-" + id
            case .lab(let id): "lab-" + id
            case .curve: "curve"
            }
        }
    }

    private var snapshot: AIInsightSnapshot? {
        guard loadedKey == snapshotKey else { return nil }
        return loadedSnapshot
    }

    private var snapshotKey: SnapshotKey {
        SnapshotKey(mode: store.mode, range: range, day: store.calendar.startOfDay(for: store.now),
                    doses: store.doses, labs: store.labs)
    }

    private var isWorking: Bool { runningID != nil }

    private var canSendQuestion: Bool {
        !isWorking && !conversation.storageUnavailable && snapshot != nil && !draft.isEmpty
    }

    private var draft: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        chat
                        Color.clear.frame(height: 1).accessibilityHidden(true).id("ai.end")
                    }
                    .padding(17)
                    .frame(maxWidth: 540, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) {
                    controls
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composer
                }
                .onChange(of: conversation.turns.count, initial: true) { oldCount, newCount in
                    guard newCount > 0 else { return }
                    if newCount == oldCount {
                        scroll.scrollTo("ai.end", anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) { scroll.scrollTo("ai.end", anchor: .bottom) }
                    }
                }
                .onChange(of: liveReply?.scrollStep) { _, step in
                    if step != nil { scroll.scrollTo("ai.end", anchor: .bottom) }
                }
            }
            .background(TrackerTheme.background.ignoresSafeArea())
            .foregroundStyle(TrackerTheme.ink)
            .navigationTitle(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "HRTrace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(assistantLabel("Done")) { dismiss() }
                        .accessibilityIdentifier("ai.done")
                }
            }
            .navigationDestination(item: $presentedReport) { report in
                AIAssistantDocumentView(
                    document: report.document,
                    allowsSourceNavigation: report.mode == store.mode,
                    onEdit: report.savedTurnID.map { id in
                        { text in try conversation.updateDocument(id, text: text) }
                    }
                ) { reference in
                    if report.mode == store.mode { show(reference) }
                }
            }
        }
        .tint(TrackerTheme.accent)
        .task(id: snapshotKey) {
            let key = snapshotKey
            let refreshed = await AIInsightSnapshot.capture(store: store, range: key.range)
            if !Task.isCancelled {
                loadedSnapshot = refreshed
                loadedKey = key
            }
        }
        .onDisappear { stop() }
        .onChange(of: question) { _, _ in
            if failure?.canRetry == true { failure = nil }
        }
        .onChange(of: store.mode) { _, _ in
            stop()
            failure = nil
            sheet = nil
        }
        .sheet(item: $sheet) { detail in
            AIAssistantRecordDetail(reference: detail.reference, store: store)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            assistantLabel("Clear chat and memory?"), isPresented: $showClearConfirmation, titleVisibility: .visible
        ) {
            Button(assistantLabel("Clear chat and memory"), role: .destructive) {
                stop()
                do { try conversation.clear(); failure = nil }
                catch { failure = Failure(message: assistantLabel("Could not update local chat and memory.")) }
            }
            Button(assistantLabel("Cancel"), role: .cancel) {}
        } message: {
            Text(assistantLabel("This removes the conversation and all saved memories from this device."))
        }
    }

    private var rangeMenu: some View {
        Menu {
            ForEach(AIRange.allCases) { option in
                Button {
                    if option != range { setRange(option) }
                } label: {
                    if option == range {
                        Label(assistantLabel("Last \(option.rawValue) days"), systemImage: "checkmark")
                    } else {
                        Text(assistantLabel("Last \(option.rawValue) days"))
                    }
                }
            }
        } label: {
            Label(assistantLabel("Last \(range.rawValue) days"), systemImage: "chevron.down")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
        }
        .accessibilityIdentifier("ai.range")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            rangeMenu
                .frame(minHeight: 44)
            Spacer(minLength: 0)
            NavigationLink {
                AIAssistantMemoryView(conversation: conversation, mode: store.mode)
            } label: {
                Text(assistantLabel("Memory"))
                    .font(.subheadline)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("ai.memories")
            Menu {
                Button(assistantLabel("Clear chat and memory"), role: .destructive) {
                    showClearConfirmation = true
                }
                .disabled(conversation.turns.isEmpty && conversation.memories.isEmpty)
                .accessibilityIdentifier("ai.clear")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel(assistantLabel("Chat actions"))
            .accessibilityIdentifier("ai.chatActions")
        }
        .padding(.horizontal, 17)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity)
        .background(TrackerTheme.background)
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 16) {
            if conversation.turns.isEmpty, liveReply == nil {
                VStack(alignment: .leading, spacing: 8) {
                    status(assistantLabel("Chat stays on this device"), icon: "lock")
                    Text(assistantLabel("Ask about your records or a general topic."))
                        .font(.subheadline)
                        .foregroundStyle(TrackerTheme.muted)
                }
            }

            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(conversation.turns) { turn in
                    VStack(alignment: .leading, spacing: 10) {
                        questionBubble(turn.question, attachmentNames: turn.attachmentNames)
                        if let document = turn.document {
                            AIAssistantDocumentCard(document: document) {
                                isQuestionFocused = false
                                presentedReport = ReportRoute(document: document, mode: turn.mode, savedTurnID: turn.id)
                            }
                        } else {
                            if let summary = turn.reasoningSummary, !summary.isEmpty {
                                AIAssistantReasoning(summary: summary)
                            }
                            if let answer = AIAssistantReplyGuard.finalText(turn.answer) {
                                Text(verbatim: answer)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("ai.answer")
                            } else if !turn.answer.isEmpty {
                                invalidReply(to: turn.question)
                            }
                            if let image = turn.generatedImage {
                                AIAssistantGeneratedImage(data: image)
                            }
                            if turn.mode == store.mode {
                                ForEach(Array(turn.sources.enumerated()), id: \.offset) { _, source in
                                    Button { show(source) } label: {
                                        Label(sourceTitle(source), systemImage: "arrow.up.right")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            } else if !turn.sources.isEmpty {
                                Text(assistantLabel("This source is no longer available for the current mode."))
                                    .font(.footnote)
                                    .foregroundStyle(TrackerTheme.muted)
                            }
                        }
                    }
                }
            }
            if let liveReply {
                questionBubble(liveReply.question, attachmentNames: [])
                if liveReply.text.isEmpty {
                    ProgressView(assistantLabel("Preparing a reply…"))
                } else {
                    Text(verbatim: AIAssistantRequest.displayedStreamText(liveReply.text))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("ai.streaming.answer")
                }
            }
        }
    }

    private func invalidReply(to original: String) -> some View {
        HStack(spacing: 8) {
            status(assistantLabel("Reply unavailable."), icon: "exclamationmark.circle")
                .accessibilityIdentifier("ai.history.invalidReply")
            replyAction("Edit question", identifier: "ai.history.editQuestion") {
                guard canEditQuestion(original) else { return }
                question = original
                isQuestionFocused = true
            }
            .disabled(!canEditQuestion(original))
        }
    }

    private func canEditQuestion(_ original: String) -> Bool {
        !isWorking && !conversation.storageUnavailable && (draft.isEmpty || question == original)
    }

    private func questionBubble(_ text: String, attachmentNames: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: text)
            ForEach(attachmentNames.indices, id: \.self) { index in
                Label(attachmentNames[index], systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(TrackerTheme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 15))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("ai.turn")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if conversation.storageUnavailable {
                status(assistantLabel("Local chat storage is unavailable."), icon: "exclamationmark.circle")
            }
            if let failure {
                HStack(spacing: 8) {
                    status(failure.message, icon: "exclamationmark.circle")
                        .accessibilityIdentifier("ai.error")
                    if failure.canRetry {
                        replyAction("Retry", identifier: "ai.retry", action: prepareQuestion)
                            .disabled(!canSendQuestion)
                    }
                }
            }
            composerField
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 8)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(TrackerTheme.background)
    }

    private var composerField: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    documentCommand(.recap)
                    documentCommand(.visit)
                }
            }
            .scrollIndicators(.hidden)
            .foregroundStyle(TrackerTheme.accent)
            .disabled(isWorking)
            HStack(alignment: .bottom, spacing: 6) {
                TextField(assistantLabel("Ask a question"), text: $question, axis: .vertical)
                    .lineLimit(3...4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                    .padding(.bottom, 8)
                    .padding(.leading, 6)
                    .focused($isQuestionFocused)
                    .accessibilityIdentifier("ai.question")
                    .disabled(isWorking || conversation.storageUnavailable)
                if isWorking {
                    composerButton(title: assistantLabel("Stop"), icon: "stop.fill", action: stop)
                        .accessibilityIdentifier("ai.stop")
                } else {
                    composerButton(title: assistantLabel("Send"), icon: "arrow.up", action: prepareQuestion)
                        .disabled(!canSendQuestion)
                        .accessibilityIdentifier("ai.send")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai.composer")
    }

    private func composerButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(TrackerTheme.accent, in: Circle())
                .foregroundStyle(TrackerTheme.accentInk)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(ComposerActionStyle())
        .accessibilityLabel(title)
    }

    private func documentCommand(_ kind: AIConversationDocument.Kind) -> some View {
        Button { openReport(kind) } label: {
            composerToolLabel(commandTitle(kind), icon: kind == .recap ? "list.bullet.rectangle" : "doc.text")
        }
        .buttonStyle(.plain)
        .disabled(snapshot == nil || isWorking)
        .accessibilityIdentifier(kind == .recap ? "ai.command.recap" : "ai.command.visit")
    }

    private func composerToolLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minHeight: 28)
            .background(TrackerTheme.surface, in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
    }

    private func commandTitle(_ kind: AIConversationDocument.Kind) -> String {
        kind == .recap ? assistantLabel("Recap") : assistantLabel("Visit summary")
    }

    private func status(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(TrackerTheme.muted)
    }

    private func replyAction(_ title: String.LocalizationValue, identifier: String, action: @escaping () -> Void)
        -> some View {
        Button(action: action) {
            Text(assistantLabel(title))
                .font(.footnote.weight(.medium))
                .foregroundStyle(TrackerTheme.accent)
                .fixedSize()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(identifier)
    }

    private func sourceTitle(_ source: AIRecordReference) -> String {
        switch source {
        case .dose: assistantLabel("View dose")
        case .lab: assistantLabel("View lab result")
        case .curve: assistantLabel("View concentration plot")
        }
    }

    private func show(_ reference: AIRecordReference) {
        isQuestionFocused = false
        if reference == .curve {
            dismiss()
            showCurve()
        } else {
            sheet = RecordDetail(reference: reference)
        }
    }

    private func setRange(_ value: AIRange) {
        stop()
        range = value
        failure = nil
    }

    private func openReport(_ kind: AIConversationDocument.Kind) {
        guard let snapshot, !isWorking else { return }
        isQuestionFocused = false
        let document = snapshot.document(kind, at: store.now, calendar: store.calendar)
        presentedReport = ReportRoute(document: document, mode: snapshot.mode, savedTurnID: nil)
    }

    private func prepareQuestion() {
        guard let snapshot, !isWorking, !conversation.storageUnavailable else { return }
        isQuestionFocused = false
        failure = nil
        guard !draft.isEmpty else { return }
        if draft.count > 500 {
            failure = Failure(message: assistantLabel("Keep the question to 500 characters or fewer."))
            return
        }
        let request = AIAssistantRequest(purpose: .question, question: draft, snapshot: snapshot)

        do {
            let context = try conversation.context(
                mode: snapshot.mode, modelLimit: AIOfflineModel.contextLimit,
                reservedTokens: AIOfflineModel.outputLimit,
                baseInput: try request.instructions(context: nil) + request.prompt
            )
            run(request, instructions: try request.instructions(context: context), recentTurns: context.recentTurns)
        } catch {
            failure = Failure(message: assistantLabel("Could not prepare this request. Shorten it and try again."))
        }
    }

    private func run(_ request: AIAssistantRequest, instructions: String, recentTurns: [AIChatTurn]) {
        let prompt = request.prompt
        runningID = request.id
        liveReply = LiveReply(question: prompt)
        requestTask = Task {
            defer {
                if runningID == request.id {
                    runningID = nil
                    requestTask = nil
                    liveReply = nil
                }
            }
            do {
                let response: String
                do {
                    response = try await generateReply(instructions, prompt, recentTurns) { text in
                        guard runningID == request.id else { return }
                        liveReply?.text = try AIAssistantReplyGuard.streamText(text)
                    }
                } catch AIAssistantReplyGuard.StreamStop.roleBoundary(let prefix) {
                    response = prefix
                }
                try Task.checkCancellation()
                guard runningID == request.id, request.snapshot.mode == store.mode else { return }
                guard let answer = AIAssistantReplyGuard.finalText(response) else {
                    throw AIAssistantRequest.InvalidReply.selection
                }
                let selection = try request.streamSelection(from: answer)
                var sources: [AIRecordReference] = []
                for source in selection.facts.compactMap(\.source) where !sources.contains(source) {
                    sources.append(source)
                }
                do {
                    try conversation.append(AIChatTurn(
                        date: store.now, mode: request.snapshot.mode, question: prompt,
                        answer: selection.answer, sources: sources
                    ))
                    question = ""
                } catch {
                    failure = Failure(message: assistantLabel("Could not update local chat and memory."))
                }
            } catch is CancellationError {
                // The draft remains available.
            } catch {
                guard runningID == request.id, !Task.isCancelled else { return }
                let modelFailure = error as? AIOfflineModel.Failure
                let canRetry: Bool
                switch modelFailure {
                case .unavailable, .missingResources: canRetry = false
                default: canRetry = true
                }
                failure = Failure(
                    message: modelFailure?.errorDescription ?? assistantLabel("Reply interrupted."),
                    canRetry: canRetry
                )
            }
        }
    }

    private func stop() {
        requestTask?.cancel()
        requestTask = nil
        runningID = nil
        liveReply = nil
    }
}

private struct AIAssistantReasoning: View {
    let summary: String

    var body: some View {
        DisclosureGroup {
            Text(verbatim: summary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)
                .textSelection(.enabled)
        } label: {
            Label(assistantLabel("Reasoning summary"), systemImage: "brain")
        }
        .font(.footnote)
        .foregroundStyle(TrackerTheme.muted)
        .padding(10)
        .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("ai.reasoningSummary")
    }
}

private struct ComposerActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.4)
    }
}

func assistantLabel(_ key: String.LocalizationValue) -> String {
    label(key, table: "AIAssistant")
}
