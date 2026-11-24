import Foundation
import Observation
import OSLog
import WatchConnectivity
import WidgetKit

enum WatchOccurrenceStatus {
    case available, pending, recorded
}

enum WatchRecordIssue: Equatable {
    case storage, planChanged
}

@MainActor
@Observable
final class WatchTrackerStore: NSObject, WCSessionDelegate {
    private struct OutboxItem: Codable {
        let command: WatchDoseCommand
        var recorded = false
    }

    private(set) var snapshot: WatchSnapshot?
    var issue: WatchRecordIssue?
    private var outbox: [OutboxItem] = []

    @ObservationIgnored private let session: WCSession?
    @ObservationIgnored private var outboxLoaded = false
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var lastAttempt: [UUID: Date] = [:]
    @ObservationIgnored private var direct: Set<UUID> = []
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "HRTTracker", category: "WatchConnectivity")

    private static var outboxURL: URL {
        URL.applicationSupportDirectory.appending(path: "watch-dose-outbox.json")
    }

    override init() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--watch-demo") {
            snapshot = Self.demoSnapshot(at: Date())
            session = nil
            super.init()
            if let snapshot, (try? WatchSnapshotCache.save(snapshot)) != nil {
                WidgetCenter.shared.reloadTimelines(ofKind: "CurrentConcentration")
            }
            return
        }
        #endif

        snapshot = WatchSnapshotCache.load()
        session = WCSession.isSupported() ? .default : nil
        super.init()
        restoreOutbox()
    }

    private func restoreOutbox() {
        guard !outboxLoaded else { return }
        do {
            outbox = try JSONDecoder().decode([OutboxItem].self, from: Data(contentsOf: Self.outboxURL))
            outboxLoaded = true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            outboxLoaded = true
        } catch {
            issue = .storage
        }
    }

    func activate() {
        guard let session else { return }
        restoreOutbox()
        if session.delegate !== self { session.delegate = self }
        if session.activationState == .activated {
            acceptApplicationContext(from: session)
            refresh()
        } else {
            session.activate()
        }
    }

    func receiveBackgroundDelivery() async {
        activate()
        guard let session else { return }
        while !Task.isCancelled && (session.activationState != .activated || session.hasContentPending) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await Task.yield()
    }

    func refresh() {
        guard let session, session.activationState == .activated else { return }
        flush()
        let now = Date()
        guard session.isReachable, lastRefresh.map({ now.timeIntervalSince($0) >= 15 }) ?? true else { return }
        lastRefresh = now
        session.sendMessage([WatchWire.requestKey: true], replyHandler: nil) { [weak self] _ in
            Task { @MainActor in self?.lastRefresh = nil }
        }
    }

    func status(of occurrence: WatchDoseOccurrence) -> WatchOccurrenceStatus {
        if occurrence.completed { return .recorded }
        guard let item = outbox.first(where: {
            $0.command.occurrenceID == occurrence.id && $0.command.version == occurrence.version
        }) else { return .available }
        return item.recorded ? .recorded : .pending
    }

    @discardableResult
    func record(_ occurrence: WatchDoseOccurrence, at now: Date = Date()) -> Bool {
        guard let snapshot, now < snapshot.planValidUntil,
              snapshot.occurrences.contains(occurrence), status(of: occurrence) == .available else {
            issue = .planChanged
            return false
        }
        let command = WatchDoseCommand(id: UUID(), occurrenceID: occurrence.id,
                                       version: occurrence.version, recordedAt: now)
        guard updateOutbox(outbox + [OutboxItem(command: command)]) else { return false }
        flush()
        return true
    }

    private func updateOutbox(_ items: [OutboxItem]) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--watch-demo") {
            outbox = items
            return true
        }
        #endif

        guard outboxLoaded else {
            issue = .storage
            return false
        }
        do {
            try FileManager.default.createDirectory(at: Self.outboxURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: Self.outboxURL, options: .atomic)
            outbox = items
            return true
        } catch {
            issue = .storage
            return false
        }
    }

    private func acceptApplicationContext(from session: WCSession) {
        let context = session.receivedApplicationContext
        if let update = WatchWire.decode(WatchSnapshot.self, from: context, kind: WatchWire.snapshotKey) {
            accept(update)
        }
    }

    private func accept(_ update: WatchSnapshot) {
        guard snapshot.map({ update.generatedAt >= $0.generatedAt }) ?? true, snapshot != update else { return }
        snapshot = update
        do {
            try WatchSnapshotCache.save(update)
            WidgetCenter.shared.reloadTimelines(ofKind: "CurrentConcentration")
        } catch {
            logger.error("Could not update the watch widget cache.")
        }

        let cutOff = update.generatedAt.addingTimeInterval(-7 * 86_400)
        let retained = outbox.filter { item in
            let confirmed = update.occurrences.contains {
                $0.id == item.command.occurrenceID && $0.version == item.command.version && $0.completed
            }
            return !confirmed && (!item.recorded || item.command.recordedAt > cutOff)
        }
        if retained.count != outbox.count, updateOutbox(retained) {
            let active = Set(retained.map { $0.command.id })
            lastAttempt = lastAttempt.filter { active.contains($0.key) }
        }
    }

    private func accept(_ receipt: WatchDoseReceipt) {
        direct.remove(receipt.id)
        guard let index = outbox.firstIndex(where: { $0.command.id == receipt.id && !$0.recorded }) else { return }
        switch receipt.result {
        case .recorded, .alreadyRecorded:
            var items = outbox
            items[index].recorded = true
            if updateOutbox(items) { lastAttempt[receipt.id] = nil }
        case .stale:
            if updateOutbox(outbox.filter { $0.command.id != receipt.id }) {
                lastAttempt[receipt.id] = nil
                issue = .planChanged
            }
        case .retry:
            lastAttempt[receipt.id] = Date()
            scheduleRetry()
        }
    }

    private func flush() {
        guard let session, session.activationState == .activated, session.isCompanionAppInstalled else { return }
        let pendingTransfers = Set(session.outstandingUserInfoTransfers.compactMap {
            WatchWire.decode(WatchDoseCommand.self, from: $0.userInfo, kind: WatchWire.commandKey)?.id
        })
        let now = Date()
        for item in outbox where !item.recorded {
            let command = item.command
            guard !pendingTransfers.contains(command.id), !direct.contains(command.id),
                  lastAttempt[command.id].map({ now.timeIntervalSince($0) >= 30 }) ?? true,
                  let payload = WatchWire.message(command, kind: WatchWire.commandKey) else { continue }
            lastAttempt[command.id] = now
            if session.isReachable {
                send(command, payload: payload, session: session)
            } else {
                enqueue(payload, session: session)
            }
        }
    }

    private func send(_ command: WatchDoseCommand, payload: [String: Any], session: WCSession) {
        direct.insert(command.id)
        session.sendMessage(payload, replyHandler: { [weak self] reply in
            let receipt = WatchWire.decode(WatchDoseReceipt.self, from: reply, kind: WatchWire.receiptKey)
            Task { @MainActor in
                guard let self else { return }
                self.direct.remove(command.id)
                if let receipt, receipt.id == command.id {
                    self.accept(receipt)
                } else {
                    self.enqueue(command)
                }
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                self?.direct.remove(command.id)
                self?.enqueue(command)
            }
        })
    }

    private func enqueue(_ command: WatchDoseCommand) {
        guard outbox.contains(where: { $0.command.id == command.id && !$0.recorded }),
              let session, session.activationState == .activated, session.isCompanionAppInstalled,
              let payload = WatchWire.message(command, kind: WatchWire.commandKey) else { return }
        enqueue(payload, session: session)
    }

    private func enqueue(_ payload: [String: Any], session: WCSession) {
        #if !targetEnvironment(simulator)
        session.transferUserInfo(payload)
        #endif
    }

    private func scheduleRetry() {
        guard retryTask == nil, session?.isReachable == true else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(31))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.flush()
            if self.outbox.contains(where: { !$0.recorded }) { self.scheduleRetry() }
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        guard activationState == .activated else { return }
        let snapshot = WatchWire.decode(WatchSnapshot.self, from: session.receivedApplicationContext,
                                        kind: WatchWire.snapshotKey)
        Task { @MainActor [weak self] in
            if let snapshot { self?.accept(snapshot) }
            self?.refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = WatchWire.decode(WatchSnapshot.self, from: applicationContext,
                                               kind: WatchWire.snapshotKey) else { return }
        Task { @MainActor [weak self] in self?.accept(snapshot) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let receipt = WatchWire.decode(WatchDoseReceipt.self, from: userInfo, kind: WatchWire.receiptKey) else { return }
        Task { @MainActor [weak self] in self?.accept(receipt) }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer,
                             error: Error?) {
        guard let command = WatchWire.decode(WatchDoseCommand.self, from: userInfoTransfer.userInfo,
                                              kind: WatchWire.commandKey) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.outbox.contains(where: { $0.command.id == command.id && !$0.recorded }) else { return }
            self.scheduleRetry()
        }
    }
}
