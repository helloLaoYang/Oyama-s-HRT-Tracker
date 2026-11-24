import Foundation

enum WatchMetric: String, CaseIterable, Codable, Hashable, Sendable {
    case e2, cpa, testosterone

    var title: LocalizedStringResource {
        switch self {
        case .e2: LocalizedStringResource("Estradiol", table: "WatchMetrics")
        case .cpa: LocalizedStringResource("Cyproterone acetate", table: "WatchMetrics")
        case .testosterone: LocalizedStringResource("Testosterone", table: "WatchMetrics")
        }
    }

    var symbol: String {
        switch self {
        case .e2: "E₂"
        case .cpa: "CPA"
        case .testosterone: "T"
        }
    }

    var unit: String {
        switch self {
        case .e2: "pg/mL"
        case .cpa: "ng/mL"
        case .testosterone: "ng/dL"
        }
    }

    func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(self == .cpa ? 0...2 : 0...1)))
    }
}

struct WatchConcentrationPoint: Codable, Hashable, Identifiable, Sendable {
    let time: Date
    let value: Double

    var id: Date { time }
}

struct WatchConcentrationSeries: Codable, Hashable, Sendable {
    let metric: WatchMetric
    /// Increasing sample times, spanning the recent history and the estimate horizon.
    let points: [WatchConcentrationPoint]
}

struct WatchSnapshot: Codable, Hashable, Sendable {
    let generatedAt: Date
    let expiresAt: Date
    let planValidUntil: Date
    let primaryMetric: WatchMetric
    let series: [WatchConcentrationSeries]
    let occurrences: [WatchDoseOccurrence]

    func points(for metric: WatchMetric) -> [WatchConcentrationPoint] {
        series.first { $0.metric == metric }?.points ?? []
    }

    func current(for metric: WatchMetric, at time: Date) -> WatchConcentrationPoint? {
        guard time < expiresAt else { return nil }
        return points(for: metric).last { $0.time <= time }
    }

    func history(for metric: WatchMetric, at time: Date) -> [WatchConcentrationPoint] {
        let start = time.addingTimeInterval(-86_400)
        return points(for: metric).filter { $0.time >= start && $0.time <= time }
    }
}

enum WatchDoseAction: String, Codable, Hashable, Sendable {
    case take, replacePatch, inject, record
}

struct WatchDoseOccurrence: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let version: String
    let title: String
    let detail: String
    let scheduledAt: Date
    let action: WatchDoseAction
    let completed: Bool
}

struct WatchDoseCommand: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let occurrenceID: String
    let version: String
    let recordedAt: Date
}

enum WatchDoseResult: String, Codable, Hashable, Sendable {
    case recorded, alreadyRecorded, stale, retry
}

struct WatchDoseReceipt: Codable, Hashable, Sendable {
    let id: UUID
    let result: WatchDoseResult
}

enum WatchWire {
    static let snapshotKey = "snapshot.v1"
    static let commandKey = "record-dose.v1"
    static let receiptKey = "dose-result.v1"
    static let requestKey = "request-snapshot.v1"

    static func message<T: Encodable>(_ value: T, kind: String) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return [kind: data]
    }

    static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any], kind: String) -> T? {
        guard let data = message[kind] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum WatchRoute {
    private static let scheme = "hrttracker-watch"
    private static let host = "concentration"

    static func url(for metric: WatchMetric?) -> URL {
        let path = metric.map { "/\($0.rawValue)" } ?? ""
        return URL(string: "\(scheme)://\(host)\(path)")!
    }

    static func matches(_ url: URL) -> Bool {
        guard url.scheme == scheme, url.host == host else { return false }
        return url.path.isEmpty || url.path == "/" || metric(from: url) != nil
    }

    static func metric(from url: URL) -> WatchMetric? {
        guard url.scheme == scheme, url.host == host, url.pathComponents.count == 2 else { return nil }
        return WatchMetric(rawValue: url.lastPathComponent)
    }
}

#if os(watchOS)
enum WatchSnapshotCache {
    private static let group = "group.com.hellolaoyang.hrttracker.dev.watch"

    static func load() -> WatchSnapshot? {
        guard let file = location, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }

    static func save(_ snapshot: WatchSnapshot) throws {
        guard let file = location else { throw CocoaError(.fileWriteNoPermission) }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static var location: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("watch-snapshot-v1.json")
    }
}
#endif
