import Foundation
import OSLog
import WatchConnectivity

@MainActor
final class PhoneWatchSync: NSObject, WCSessionDelegate {
    private let store: TrackerStore
    private let session: WCSession?
    private var requestedInputs: PhoneWatchInputs?
    private var lastSent: (inputs: PhoneWatchInputs, message: [String: Any])?
    private var refreshTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HRTTracker", category: "PhoneWatchSync")

    init(store: TrackerStore) {
        self.store = store
        session = !store.isDemo && WCSession.isSupported() ? .default : nil
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func refresh(resend: Bool = false) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            return
        }
        let date = Date()
        let inputs = PhoneWatchInputs(store: store, at: date)
        if requestedInputs == inputs {
            if resend, let lastSent, lastSent.inputs == inputs { publish(lastSent.message) }
            return
        }
        requestedInputs = inputs
        let occurrences = store.watchPlanOccurrences(at: date)
        let calendar = store.calendar
        let nextDay = calendar.date(byAdding: .day, value: 1, to: inputs.day) ?? inputs.day
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let calculation = Task.detached(priority: .utility) { inputs.concentrationSeries(at: date) }
            let series = await withTaskCancellationHandler {
                await calculation.value
            } onCancel: {
                calculation.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            let snapshot = WatchSnapshot(generatedAt: date, expiresAt: PhoneWatchInputs.expiration(after: date),
                                         planValidUntil: nextDay, primaryMetric: inputs.primaryMetric, series: series,
                                         occurrences: occurrences)
            guard let message = WatchWire.message(snapshot, kind: WatchWire.snapshotKey) else {
                requestedInputs = nil
                return
            }
            if publish(message) { lastSent = (inputs, message) }
        }
    }

    @discardableResult
    private func publish(_ message: [String: Any]) -> Bool {
        guard let session, session.activationState == .activated else { return false }
        do {
            try session.updateApplicationContext(message)
            return true
        } catch {
            requestedInputs = nil
            logger.warning("Could not send the Watch snapshot.")
            return false
        }
    }

    private func process(_ command: WatchDoseCommand) -> [String: Any] {
        let result = store.recordWatchDose(command)
        switch result {
        case .recorded:
            refresh()
            Task { await MedicationNotifications.refresh(for: store) }
        case .alreadyRecorded, .stale:
            refresh(resend: true)
        case .retry:
            break
        }
        return WatchWire.message(WatchDoseReceipt(id: command.id, result: result), kind: WatchWire.receiptKey) ?? [:]
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor [weak self] in self?.refresh(resend: true) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.requestedInputs = nil
            self?.lastSent = nil
            self?.refreshTask?.cancel()
            self?.session?.activate()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refresh(resend: true) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let requestsSnapshot = message[WatchWire.requestKey] as? Bool == true
        let command = WatchWire.decode(WatchDoseCommand.self, from: message, kind: WatchWire.commandKey)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if requestsSnapshot { refresh(resend: true) }
            if let command, let session = self.session, session.activationState == .activated {
                session.transferUserInfo(process(command))
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let requestsSnapshot = message[WatchWire.requestKey] as? Bool == true
        let command = WatchWire.decode(WatchDoseCommand.self, from: message, kind: WatchWire.commandKey)
        Task { @MainActor [weak self] in
            if requestsSnapshot { self?.refresh(resend: true) }
            if let command, let self { replyHandler(process(command)) }
            else { replyHandler([:]) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let command = WatchWire.decode(WatchDoseCommand.self, from: userInfo, kind: WatchWire.commandKey) else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let session = self.session, session.activationState == .activated else { return }
            session.transferUserInfo(process(command))
        }
    }
}
