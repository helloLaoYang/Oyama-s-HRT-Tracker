import HRTEngine
import SwiftData
import SwiftUI
import UIKit

@main
@MainActor
struct HRTTrackerApp: App {
    private let startup: Result<(container: ModelContainer, store: TrackerStore, watchSync: PhoneWatchSync), Error>

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
            return (container, store, PhoneWatchSync(store: store))
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .success(let state):
                TrackerRoot(store: state.store, watchSync: state.watchSync)
                    .modelContainer(state.container)
            case .failure:
                ContentUnavailableView("Cannot open tracker data", systemImage: "exclamationmark.triangle",
                                       description: Text("Close the app and try again."))
            }
        }
    }
}

private enum TrackerTab: String, CaseIterable {
    case overview, history, labs, settings

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .history: "Records"
        case .labs: "Checks"
        case .settings: "Settings"
        }
    }

    var icon: Image {
        switch self {
        case .overview: TrackerTheme.navigationIcon("house")
        case .history: TrackerTheme.navigationIcon("list.bullet.rectangle.portrait")
        case .labs: TrackerTheme.labNavigationIcon
        case .settings: TrackerTheme.navigationIcon("gearshape")
        }
    }
}

private struct TrackerRoot: View {
    let store: TrackerStore
    let watchSync: PhoneWatchSync
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack { OverviewView(store: store) }
                .tabItem { tab(.overview) }
                .accessibilityIdentifier("tab.overview")

            NavigationStack { HistoryView(store: store) }
                .tabItem { tab(.history) }
                .accessibilityIdentifier("tab.history")

            NavigationStack { LabsView(store: store) }
                .tabItem { tab(.labs) }
                .accessibilityIdentifier("tab.labs")

            NavigationStack { TrackerSettingsView(store: store) }
                .tabItem { tab(.settings) }
                .accessibilityIdentifier("tab.settings")
        }
        .tint(TrackerTheme.accent)
        .preferredColorScheme(preferredScheme)
        .saturation(store.appearance == .mono ? 0 : 1)
        .task(id: ReminderInputs(
            enabled: store.remindersEnabled, mode: store.mode, plans: store.plans, doses: store.doses,
            day: store.calendar.startOfDay(for: store.now), active: scenePhase == .active
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
    let active: Bool
}
