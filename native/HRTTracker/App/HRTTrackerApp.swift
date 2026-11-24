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
        let modelSettings: AIModelSettings
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
                           modelSettings: AIModelSettings(inMemory: memoryOnly),
                           conversation: AIConversationStore(inMemory: memoryOnly))
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .success(let state):
                TrackerRoot(store: state.store, watchSync: state.watchSync,
                            modelSettings: state.modelSettings, conversation: state.conversation)
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
        case .assistant: "AI"
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
    let modelSettings: AIModelSettings
    let conversation: AIConversationStore
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .system
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var systemLocale
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: TrackerTab = .overview
    @State private var showsAssistant = false
    @State private var opensCurveAfterAssistant = false
    @State private var concentrationScrollRequest = 0

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

            Color.clear
                .tabItem { tab(.assistant) }
                .tag(TrackerTab.assistant)
                .accessibilityIdentifier("tab.assistant")

            NavigationStack { LabsView(store: store) }
                .tabItem { tab(.labs) }
                .tag(TrackerTab.labs)
                .accessibilityIdentifier("tab.labs")

            NavigationStack { TrackerSettingsView(store: store, modelSettings: modelSettings) }
                .tabItem { tab(.settings) }
                .tag(TrackerTab.settings)
                .accessibilityIdentifier("tab.settings")
        }
        .id(language)
        .sheet(isPresented: $showsAssistant, onDismiss: assistantDismissed) {
            AIAssistantView(store: store, modelSettings: modelSettings, conversation: conversation) {
                opensCurveAfterAssistant = true
                showsAssistant = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .environment(\.locale, language.locale ?? systemLocale)
        .tint(TrackerTheme.accent)
        .preferredColorScheme(preferredScheme)
        .saturation(store.appearance == .mono ? 0 : 1)
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

    private var tabSelection: Binding<TrackerTab> {
        Binding(get: { selectedTab }, set: { tab in
            if tab == .assistant {
                showsAssistant = true
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
            if tab == .assistant {
                assistantIcon
            } else {
                tab.icon
            }
        }
    }

    private var assistantIcon: Image {
        let size = CGSize(width: 28, height: 28)
        let style: UIUserInterfaceStyle = (preferredScheme ?? colorScheme) == .dark ? .dark : .light
        let traits = UITraitCollection(userInterfaceStyle: style)
        let monochrome = store.appearance == .mono
        let fill = UIColor(monochrome ? TrackerTheme.subtle : TrackerTheme.wash).resolvedColor(with: traits)
        let tint = UIColor(monochrome ? TrackerTheme.ink : TrackerTheme.accent).resolvedColor(with: traits)
        let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let icon = UIImage(systemName: "sparkles", withConfiguration: configuration)?.withTintColor(tint, renderingMode: .alwaysOriginal)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            fill.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            if let icon {
                icon.draw(at: CGPoint(x: (size.width - icon.size.width) / 2, y: (size.height - icon.size.height) / 2))
            }
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
    }
}

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
