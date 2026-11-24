import HRTEngine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AIAssistantView: View {
    let store: TrackerStore
    let modelSettings: AIModelSettings
    let conversation: AIConversationStore
    let showCurve: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @FocusState private var isQuestionFocused: Bool

    @State private var section: Section = .recap
    @State private var range: AIRange = .month
    @State private var loadedSnapshot: AIInsightSnapshot?
    @State private var loadedKey: SnapshotKey?
    @State private var model: Model = .apple
    @State private var question = ""
    @State private var editedReport: String?
    @State private var reportEditor: ReportEditor?
    @State private var requestedRange: AIRange?
    @State private var reviewedFacts: [AIInsightFact]?
    @State private var reportFacts: [AIInsightFact]?
    @State private var sheet: DetailSheet?
    @State private var requestTask: Task<Void, Never>?
    @State private var runningID: UUID?
    @State private var failure: String?
    @State private var showClearConfirmation = false
    @State private var showModelSettings = false

    private enum Section: String, CaseIterable {
        case recap, report, ask

        var title: String {
            switch self {
            case .recap: assistantLabel("Recap")
            case .report: assistantLabel("Visit summary")
            case .ask: assistantLabel("Q&A")
            }
        }
    }

    private enum Model: String, CaseIterable {
        case apple, compatible
    }

    private struct ReportEditor: Identifiable {
        let id = UUID()
        let text: String
    }

    private struct SnapshotKey: Equatable {
        let mode: HRTMode
        let range: AIRange
        let day: Date
        let doses: [DoseEvent]
        let labs: [LabResult]
    }

    private struct Approval {
        let request: AIAssistantRequest
        let profile: AIProviderProfile
        let memory: AIConversationContext?
    }

    private enum DetailSheet: Identifiable {
        case consent(Approval)
        case record(AIRecordReference)

        var id: String {
            switch self {
            case .consent(let approval): approval.request.id.uuidString
            case .record(let reference):
                switch reference {
                case .dose(let id): "dose-" + id
                case .lab(let id): "lab-" + id
                case .curve: "curve"
                }
            }
        }
    }

    private var snapshot: AIInsightSnapshot? {
        guard loadedSnapshot?.range == range, loadedSnapshot?.mode == store.mode else { return nil }
        return loadedSnapshot
    }

    private var snapshotKey: SnapshotKey {
        SnapshotKey(mode: store.mode, range: range, day: store.calendar.startOfDay(for: store.now),
                    doses: store.doses, labs: store.labs)
    }

    private var modelUnavailable: String? {
        switch model {
        case .apple: AIModelClient.appleUnavailableReason(locale: locale)
        case .compatible: modelSettings.profile == nil ? assistantLabel("Configure a compatible model to continue.") : nil
        }
    }

    private var isWorking: Bool { runningID != nil }

    private var reportText: String {
        if let editedReport { return editedReport }
        guard let snapshot else { return "" }
        guard let reportFacts, !reportFacts.isEmpty else { return snapshot.report }
        return snapshot.report + "\n\n" + assistantLabel("Highlights") + "\n" + reportFacts.map(\.text).joined(separator: "\n")
    }

    private var hasCurrentRecords: Bool {
        guard let snapshot else { return false }
        return !snapshot.doses.isEmpty || !snapshot.labs.isEmpty || snapshot.facts.contains { $0.source == .curve }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        controls
                        if conversation.storageUnavailable {
                            status(assistantLabel("Local chat storage is unavailable."), icon: "exclamationmark.circle")
                        }
                        if let failure {
                            status(failure, icon: "exclamationmark.circle")
                                .accessibilityIdentifier("ai.error")
                        }
                        switch section {
                        case .recap: recap
                        case .report: report
                        case .ask: chat
                        }
                        Color.clear.frame(height: 1).accessibilityHidden(true).id("ai.end")
                    }
                    .padding(17)
                    .frame(maxWidth: 540, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if section == .ask { questionBar }
                    if section == .report, snapshot != nil { reportBar }
                }
                .onChange(of: conversation.turns.count) { _, _ in
                    if section == .ask {
                        withAnimation(.easeOut(duration: 0.18)) { scroll.scrollTo("ai.end", anchor: .bottom) }
                    }
                }
                .onChange(of: section) { _, current in
                    if current == .ask, !conversation.turns.isEmpty {
                        scroll.scrollTo("ai.end", anchor: .bottom)
                    }
                }
            }
            .background(TrackerTheme.background.ignoresSafeArea())
            .foregroundStyle(TrackerTheme.ink)
            .navigationTitle(assistantLabel("Record assistant"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(assistantLabel("Done")) { dismiss() }
                        .accessibilityIdentifier("ai.done")
                }
            }
            .navigationDestination(isPresented: $showModelSettings) {
                AIModelSettingsView(settings: modelSettings)
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
        .onChange(of: store.mode) { _, _ in
            stop()
            failure = nil
            editedReport = nil
            reviewedFacts = nil
            reportFacts = nil
            sheet = nil
        }
        .sheet(item: $sheet) { current in
            switch current {
            case .consent(let approval):
                AIAssistantConsent(
                    request: approval.request, profile: approval.profile, memory: approval.memory
                ) { includeMemory in
                    sheet = nil
                    guard model == .compatible, approval.profile == modelSettings.profile,
                          approval.request.snapshot.mode == store.mode,
                          approval.request.snapshot.range == range,
                          approval.request.snapshot.facts == snapshot?.facts,
                          loadedKey == snapshotKey else {
                        failure = assistantLabel("The model or records changed. Start the request again.")
                        return
                    }
                    run(approval.request, context: includeMemory ? approval.memory : nil, profile: approval.profile)
                }
                .presentationDetents([.large])
            case .record(let reference):
                AIAssistantRecordDetail(reference: reference, store: store)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $reportEditor) { editor in
            AIAssistantReportEditor(text: editor.text) { editedReport = $0 }
        }
        .confirmationDialog(
            assistantLabel("Replace the edited summary?"),
            isPresented: Binding(get: { requestedRange != nil }, set: { if !$0 { requestedRange = nil } }),
            titleVisibility: .visible
        ) {
            Button(assistantLabel("Replace summary"), role: .destructive) {
                guard let requestedRange else { return }
                editedReport = nil
                setRange(requestedRange)
                self.requestedRange = nil
            }
            Button(assistantLabel("Cancel"), role: .cancel) { requestedRange = nil }
        }
        .confirmationDialog(
            assistantLabel("Clear chat and memory?"), isPresented: $showClearConfirmation, titleVisibility: .visible
        ) {
            Button(assistantLabel("Clear chat and memory"), role: .destructive) {
                stop()
                do { try conversation.clear(); failure = nil }
                catch { failure = assistantLabel("Could not update local chat and memory.") }
            }
            Button(assistantLabel("Cancel"), role: .cancel) {}
        } message: {
            Text(assistantLabel("This removes the conversation and all saved memories from this device."))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                Picker(assistantLabel("Assistant view"), selection: $section) {
                    ForEach(Section.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                            .accessibilityIdentifier("ai.segment.\(choice.rawValue)")
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)

                Picker(assistantLabel("Assistant view"), selection: $section) {
                    ForEach(Section.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity)
            .onChange(of: section) { _, _ in
                isQuestionFocused = false
                if !isWorking { failure = nil }
            }

            HStack(alignment: .firstTextBaseline) {
                Menu {
                    ForEach(AIRange.allCases) { option in
                        Button {
                            if option != range {
                                if editedReport != nil { requestedRange = option }
                                else { setRange(option) }
                            }
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
                Spacer(minLength: 12)
                modelMenu
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            Button { model = .apple } label: {
                if model == .apple { Label(assistantLabel("Apple on-device"), systemImage: "checkmark") }
                else { Text(assistantLabel("Apple on-device")) }
            }
            if let profile = modelSettings.profile {
                Button { model = .compatible } label: {
                    if model == .compatible { Label(profile.model, systemImage: "checkmark") }
                    else { Text(verbatim: profile.model) }
                }
            }
            Button(assistantLabel("Model settings")) { showModelSettings = true }
            .accessibilityIdentifier("ai.modelSettings")
        } label: {
            Label(
                model == .apple ? assistantLabel("Apple on-device") :
                    modelSettings.profile?.model ?? assistantLabel("Compatible model"),
                systemImage: "chevron.down"
            )
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .font(.subheadline)
        }
        .disabled(isWorking)
        .accessibilityIdentifier("ai.modelMenu")
        .onChange(of: model) { _, _ in failure = nil }
    }

    @ViewBuilder
    private var recap: some View {
        if let snapshot {
            if !hasCurrentRecords {
                status(assistantLabel("No records in this range."), icon: "tray")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(reviewedFacts ?? snapshot.facts) { fact in
                        factRow(fact)
                    }
                }
                if modelUnavailable == nil { organizeButton(.recap) }
            }
        } else {
            ProgressView(assistantLabel("Reading records…"))
        }
    }

    @ViewBuilder
    private var report: some View {
        if snapshot != nil {
            Text(verbatim: editedReport ?? snapshot?.report ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier("ai.report.text")

            if let reportFacts {
                VStack(alignment: .leading, spacing: 8) {
                    Text(assistantLabel("Highlights")).font(.headline.weight(.medium))
                    ForEach(reportFacts) { fact in factRow(fact) }
                }
            }
            if modelUnavailable == nil, hasCurrentRecords {
                organizeButton(.report)
            }
        } else {
            ProgressView(assistantLabel("Reading records…"))
        }
    }

    private func organizeButton(_ purpose: AIAssistantRequest.Purpose) -> some View {
        HStack {
            Spacer()
            if isWorking {
                Button(assistantLabel("Stop"), action: stop)
                    .accessibilityIdentifier("ai.stop")
            } else {
                Button(assistantLabel("Organize with model")) { prepare(purpose) }
                    .accessibilityIdentifier("ai.organize")
            }
        }
        .font(.subheadline)
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(assistantLabel("Chat stays on this device"), systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(TrackerTheme.muted)
                Spacer(minLength: 0)
                NavigationLink {
                    AIAssistantMemoryView(conversation: conversation, mode: store.mode)
                } label: {
                    Text(assistantLabel("Memory")).font(.subheadline)
                }
                .accessibilityIdentifier("ai.memories")
                if !conversation.turns.isEmpty || !conversation.memories.isEmpty {
                    Menu {
                        Button(assistantLabel("Clear chat and memory"), role: .destructive) {
                            showClearConfirmation = true
                        }
                        .accessibilityIdentifier("ai.clear")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .accessibilityLabel(assistantLabel("Chat actions"))
                }
            }

            if let modelUnavailable {
                VStack(alignment: .leading, spacing: 8) {
                    status(modelUnavailable, icon: "sparkles")
                    Button(assistantLabel("Model settings")) { showModelSettings = true }
                    .font(.subheadline)
                    .accessibilityIdentifier("ai.modelSettings")
                }
            }

            if conversation.turns.isEmpty, modelUnavailable == nil {
                Text(assistantLabel("Ask about your logged doses or measurements."))
                    .font(.subheadline)
                    .foregroundStyle(TrackerTheme.muted)
            }

            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(conversation.turns) { turn in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: turn.question)
                            .padding(10)
                            .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 12))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .accessibilityIdentifier("ai.turn")
                        Text(verbatim: turn.answer)
                            .textSelection(.enabled)
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
            if isWorking {
                ProgressView(assistantLabel("Organizing records…"))
            }
        }
    }

    private var questionBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(assistantLabel("Ask about your records"), text: $question, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(TrackerTheme.subtle, in: RoundedRectangle(cornerRadius: 10))
                .focused($isQuestionFocused)
                .accessibilityIdentifier("ai.question")
                .disabled(isWorking || modelUnavailable != nil || conversation.storageUnavailable)
            if isWorking {
                Button(assistantLabel("Stop"), action: stop)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ai.stop")
            } else {
                Button(assistantLabel("Send")) { prepare(.question) }
                    .buttonStyle(.borderedProminent)
                    .disabled(modelUnavailable != nil || conversation.storageUnavailable || snapshot == nil ||
                              question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("ai.send")
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity)
        .background(TrackerTheme.background)
    }

    private var reportBar: some View {
        HStack(spacing: 14) {
            Button(assistantLabel("Edit")) { reportEditor = ReportEditor(text: reportText) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("ai.report.edit")
            NavigationLink {
                AIAssistantReportPreview(text: reportText)
            } label: {
                Text(assistantLabel("Preview export"))
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("ai.report.preview")
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity)
        .background(TrackerTheme.background)
    }

    @ViewBuilder
    private func factRow(_ fact: AIInsightFact) -> some View {
        if let source = fact.source {
            Button { show(source) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: fact.text)
                        .foregroundStyle(TrackerTheme.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ai.fact.\(fact.id)")
        } else {
            Text(verbatim: fact.text)
                .padding(.vertical, 9)
        }
    }

    private func status(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(TrackerTheme.muted)
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
            sheet = .record(reference)
        }
    }

    private func setRange(_ value: AIRange) {
        stop()
        range = value
        failure = nil
        reviewedFacts = nil
        reportFacts = nil
    }

    private func prepare(_ purpose: AIAssistantRequest.Purpose) {
        guard let snapshot, !isWorking, modelUnavailable == nil else { return }
        guard loadedKey == snapshotKey else {
            failure = assistantLabel("The model or records changed. Start the request again.")
            return
        }
        isQuestionFocused = false
        failure = nil
        let draft = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if purpose == .question, draft.isEmpty { return }
        if purpose == .question, draft.count > 500 {
            failure = assistantLabel("Keep the question to 500 characters or fewer.")
            return
        }
        let request = AIAssistantRequest(purpose: purpose, question: purpose == .question ? draft : nil, snapshot: snapshot)
        guard !request.facts.isEmpty else {
            failure = assistantLabel("There are no records to answer from in this range.")
            return
        }

        do {
            let baseInput = AIAssistantRequest.instructions + (try request.input(context: nil, includeRecentTurns: false))
            switch model {
            case .apple:
                let context = conversation.storageUnavailable ? nil : try conversation.context(
                    mode: snapshot.mode, modelLimit: AIModelClient.appleContextLimit(),
                    reservedTokens: AIModelClient.appleOutputLimit, baseInput: baseInput, includeRecentTurns: true
                )
                run(request, context: context)
            case .compatible:
                guard let profile = modelSettings.profile else { return }
                let limit = AIModelClient.compatibleContextLimit(for: profile)
                let outputLimit = AIModelClient.compatibleOutputLimit
                guard AIConversationStore.fits(modelLimit: limit, reservedTokens: outputLimit, baseInput: baseInput) else {
                    throw AIModelClientError.contextLimitExceeded
                }
                var memory = conversation.storageUnavailable ? nil : try? conversation.context(
                    mode: snapshot.mode, modelLimit: limit, reservedTokens: outputLimit,
                    baseInput: baseInput, includeRecentTurns: false
                )
                if let context = memory {
                    let previewedInput = AIAssistantRequest.instructions + (try request.input(context: context, includeRecentTurns: false))
                    if !AIConversationStore.fits(modelLimit: limit, reservedTokens: outputLimit, baseInput: previewedInput) {
                        memory = nil
                    }
                }
                sheet = .consent(Approval(request: request, profile: profile, memory: memory))
            }
        } catch {
            failure = assistantLabel("Could not prepare this request. Shorten it and try again.")
        }
    }

    private func run(_ request: AIAssistantRequest, context: AIConversationContext?, profile: AIProviderProfile? = nil) {
        guard !isWorking else { return }
        runningID = request.id
        requestTask = Task {
            defer {
                if runningID == request.id {
                    runningID = nil
                    requestTask = nil
                }
            }
            do {
                let response: String
                if let profile {
                    let input = try request.input(context: context, includeRecentTurns: false)
                    let apiKey = try modelSettings.apiKey(for: profile)
                    response = try await AIModelClient.completeCompatible(
                        system: AIAssistantRequest.instructions, input: input, profile: profile, apiKey: apiKey
                    )
                } else {
                    response = try await completeOnDevice(request, context: context)
                }
                try Task.checkCancellation()
                guard runningID == request.id, request.snapshot.mode == store.mode else { return }
                let selection: AIAssistantRequest.Selection
                do { selection = try request.selection(from: response) }
                catch {
                    failure = assistantLabel("The answer did not match the available records. Try again.")
                    return
                }

                if request.purpose == .question, let prompt = request.question {
                    let answer = selection.outOfScope ? assistantLabel("I can help review your saved records and estimates. Take treatment decisions to your care team.") :
                        selection.facts.map(\.text).joined(separator: "\n\n")
                    var sources: [AIRecordReference] = []
                    for source in selection.facts.compactMap(\.source) where !sources.contains(source) {
                        sources.append(source)
                    }
                    do {
                        try conversation.append(AIChatTurn(
                            id: UUID(), date: store.now, mode: request.snapshot.mode, question: prompt,
                            answer: answer, sources: sources
                        ))
                        question = ""
                    } catch {
                        failure = assistantLabel("Could not update local chat and memory.")
                    }
                } else if selection.outOfScope {
                    failure = assistantLabel("The answer did not match the available records. Try again.")
                } else if request.purpose == .recap {
                    reviewedFacts = selection.facts
                } else {
                    reportFacts = selection.facts
                }
            } catch is CancellationError {
                // The draft remains available.
            } catch {
                guard runningID == request.id, !Task.isCancelled else { return }
                if let safeError = error as? AIModelClientError {
                    failure = safeError.errorDescription ?? assistantLabel("Could not complete the request. Try again.")
                } else {
                    failure = assistantLabel("Could not complete the request. Try again.")
                }
            }
        }
    }

    private func completeOnDevice(_ request: AIAssistantRequest, context: AIConversationContext?) async throws -> String {
        let system = AIAssistantRequest.instructions
        let localLimit = AIModelClient.appleContextLimit()
        let outputLimit = AIModelClient.appleOutputLimit
        let candidates = try [
            request.input(context: context, includeRecentTurns: true),
            request.input(context: context, includeRecentTurns: false),
            request.input(context: nil, includeRecentTurns: false)
        ]
        var attempted = Set<String>()
        for input in candidates where attempted.count < 2 && !attempted.contains(input) {
            try Task.checkCancellation()
            let fits: Bool
            if let count = await AIModelClient.appleTokenCount(system: system, input: input), let localLimit {
                fits = count < localLimit - outputLimit - 32
            } else {
                fits = AIConversationStore.fits(modelLimit: localLimit, reservedTokens: outputLimit,
                                                baseInput: system + input)
            }
            guard fits else { continue }
            attempted.insert(input)
            do {
                return try await AIModelClient.completeApple(system: system, input: input, locale: locale)
            } catch AIModelClientError.contextLimitExceeded {
                continue
            }
        }
        throw AIModelClientError.contextLimitExceeded
    }

    private func stop() {
        requestTask?.cancel()
        requestTask = nil
        runningID = nil
    }
}

func assistantLabel(_ key: String.LocalizationValue) -> String {
    label(key, table: "AIAssistant")
}
