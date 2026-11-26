import HRTEngine
import SwiftData
import SwiftUI
import UIKit

@main
@MainActor
struct HRTTrackerApp: App {
    private let startup: Result<Startup, Error>

    private struct Startup {
        let container: ModelContainer
        let store: TrackerStore
        let watchSync: PhoneWatchSync
        let conversation: AIConversationStore
    }

    init() {
        let navigationBar = UINavigationBar.appearance()
        let backIndicator = TrackerTheme.navigationSymbol("chevron.backward")
        navigationBar.backIndicatorImage = backIndicator
        navigationBar.backIndicatorTransitionMaskImage = backIndicator

        let memoryOnly = ProcessInfo.processInfo.arguments.contains("--demo")
        startup = Result {
            let schema = TrackerStore.schema
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: memoryOnly)
            )
            let store = TrackerStore(context: container.mainContext, demo: memoryOnly)
            return Startup(container: container, store: store, watchSync: PhoneWatchSync(store: store),
                           conversation: AIConversationStore(inMemory: memoryOnly))
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .success(let state):
                TrackerRoot(store: state.store, watchSync: state.watchSync, conversation: state.conversation)
                    .modelContainer(state.container)
            case .failure:
                ContentUnavailableView("Cannot open tracker data", systemImage: "exclamationmark.triangle",
                                       description: Text("Close the app and try again."))
            }
        }
    }
}

private enum TrackerTab: String, CaseIterable {
    case overview, history, assistant, labs, settings

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .history: "Records"
        case .assistant: "HRTrace"
        case .labs: "Checks"
        case .settings: "Settings"
        }
    }

    var icon: Image {
        switch self {
        case .overview: TrackerTheme.navigationIcon("house")
        case .history: TrackerTheme.navigationIcon("list.bullet.rectangle.portrait")
        case .assistant: TrackerTheme.navigationIcon("sparkles")
        case .labs: TrackerTheme.labNavigationIcon
        case .settings: TrackerTheme.navigationIcon("gearshape")
        }
    }
}

private struct TrackerRoot: View {
    let store: TrackerStore
    let watchSync: PhoneWatchSync
    let conversation: AIConversationStore
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .system
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var systemLocale
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: TrackerTab = .overview
    @State private var keyboardVisible = false
    @State private var showsAssistant = false
    @State private var opensCurveAfterAssistant = false
    @State private var concentrationScrollRequest = 0
    #if DEBUG && targetEnvironment(simulator)
    @State private var assistantTestReplies = AssistantTestReplies()
    #endif

    var body: some View {
        TabView(selection: tabSelection) {
            NavigationStack { OverviewView(store: store, concentrationScrollRequest: concentrationScrollRequest) }
                .id(concentrationScrollRequest)
                .tabItem { tab(.overview) }
                .tag(TrackerTab.overview)
                .accessibilityIdentifier("tab.overview")

            NavigationStack { HistoryView(store: store) }
                .tabItem { tab(.history) }
                .tag(TrackerTab.history)
                .accessibilityIdentifier("tab.history")

            if hasAssistant {
                Color.clear
                    .accessibilityHidden(usesInlineAssistant)
                    .tabItem {
                        if usesInlineAssistant {
                            Text(verbatim: " ").accessibilityHidden(true)
                        } else {
                            tab(.assistant)
                        }
                    }
                    .tag(TrackerTab.assistant)
            }

            NavigationStack { LabsView(store: store) }
                .tabItem { tab(.labs) }
                .tag(TrackerTab.labs)
                .accessibilityIdentifier("tab.labs")

            NavigationStack { TrackerSettingsView(store: store) }
                .tabItem { tab(.settings) }
                .tag(TrackerTab.settings)
                .accessibilityIdentifier("tab.settings")
        }
        .id(language)
        .overlay(alignment: .bottom) {
            if hasAssistant, usesInlineAssistant, !keyboardVisible {
                assistantButton
                    .offset(y: 3)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .sheet(isPresented: $showsAssistant, onDismiss: assistantDismissed) {
            assistantSheet
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .environment(\.locale, language.locale ?? systemLocale)
        .tint(TrackerTheme.accent)
        .preferredColorScheme(preferredScheme)
        .saturation(store.appearance == .mono ? 0 : 1)
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if isAssistantUITest, conversation.turns.isEmpty {
                try? conversation.append(AIChatTurn(
                    date: .now, mode: store.mode, question: "旧问题",
                    answer: "User: 旧问题\nAssistant: User: 你是谁", sources: []
                ))
            }
        }
        #endif
        .task(id: ReminderInputs(
            enabled: store.remindersEnabled, mode: store.mode, plans: store.plans, doses: store.doses,
            day: store.calendar.startOfDay(for: store.now), language: language, active: scenePhase == .active
        )) {
            guard scenePhase == .active else { return }
            await MedicationNotifications.refresh(for: store)
        }
        .task(id: WatchRefreshInputs(inputs: PhoneWatchInputs(store: store, at: store.now),
                                     active: scenePhase == .active)) {
            if scenePhase == .active { watchSync.refresh() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                store.refreshClock()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var hasAssistant: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if isAssistantUITest { return true }
        #endif
        return AIOfflineModel.isSupported
    }

    private var assistantSheet: AIAssistantView {
        #if DEBUG && targetEnvironment(simulator)
        if isAssistantUITest {
            return AIAssistantView(
                store: store, conversation: conversation, prepareModel: {},
                generateReply: { [assistantTestReplies] _, _, update in
                    try await assistantTestReplies.generate(onUpdate: update)
                },
                showCurve: openCurveFromAssistant
            )
        }
        #endif
        return AIAssistantView(store: store, conversation: conversation, showCurve: openCurveFromAssistant)
    }

    #if DEBUG && targetEnvironment(simulator)
    private var isAssistantUITest: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--demo") && arguments.contains("--assistant-ui-test")
    }
    #endif

    private func openCurveFromAssistant() {
        opensCurveAfterAssistant = true
        showsAssistant = false
    }

    private var usesInlineAssistant: Bool { horizontalSizeClass == .compact }

    private var tabSelection: Binding<TrackerTab> {
        Binding(get: { selectedTab }, set: { tab in
            if tab == .assistant {
                showsAssistant = hasAssistant
            } else {
                selectedTab = tab
            }
        })
    }

    private func assistantDismissed() {
        guard opensCurveAfterAssistant else { return }
        opensCurveAfterAssistant = false
        concentrationScrollRequest += 1
        selectedTab = .overview
    }

    private var preferredScheme: ColorScheme? {
        switch store.appearance {
        case .light: .light
        case .dark: .dark
        case .system, .mono: nil
        }
    }

    private func tab(_ tab: TrackerTab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            tab.icon
        }
    }

    private var assistantButton: some View {
        Button {
            showsAssistant = true
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26.5, weight: .light))
                    .frame(height: 26)
                Text(TrackerTab.assistant.title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(TrackerTheme.ink)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(TrackerTab.assistant.title))
        .accessibilityIdentifier("tab.assistant")
    }
}

#if DEBUG && targetEnvironment(simulator)
private actor AssistantTestReplies {
    private var hasSent = false

    func generate(onUpdate: @MainActor @Sendable (String) throws -> Void) async throws -> String {
        if !hasSent {
            hasSent = true
            let text = "User: 测试\nAssistant: User: 你是谁"
            try await onUpdate(text)
            return text
        }
        let text = "测试通过，我可以帮你。"
        try await onUpdate(text)
        return text
    }
}
#endif

private struct WatchRefreshInputs: Equatable {
    let inputs: PhoneWatchInputs
    let active: Bool
}

private struct ReminderInputs: Equatable {
    let enabled: Bool
    let mode: HRTMode
    let plans: [MedicationPlan]
    let doses: [DoseEvent]
    let day: Date
    let language: AppLanguage
    let active: Bool
}
