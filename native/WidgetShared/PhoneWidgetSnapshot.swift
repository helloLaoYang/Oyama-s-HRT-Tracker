import Foundation

struct PhoneWidgetSnapshot: Codable, Sendable {
    let generatedAt: Date
    let expiresAt: Date
    let primaryMetric: WatchMetric
    private let series: [WatchConcentrationSeries]

    init(_ snapshot: WatchSnapshot) {
        generatedAt = snapshot.generatedAt
        expiresAt = snapshot.expiresAt
        primaryMetric = snapshot.primaryMetric
        series = snapshot.series
    }

    func points(for metric: WatchMetric) -> [WatchConcentrationPoint] {
        series.first { $0.metric == metric }?.points ?? []
    }

    func current(for metric: WatchMetric, at time: Date) -> WatchConcentrationPoint? {
        guard time < expiresAt else { return nil }
        return points(for: metric).last { $0.time <= time }
    }

    func history(for metric: WatchMetric, at time: Date) -> [WatchConcentrationPoint] {
        guard time < expiresAt else { return [] }
        let start = time.addingTimeInterval(-86_400)
        return points(for: metric).filter { $0.time >= start && $0.time <= time }
    }
}

enum PhoneWidgetSnapshotCache {
    static let kind = "PhoneCurrentConcentration"
    private static let group = "group.com.hellolaoyang.hrttracker.dev.watch"

    static func load() -> PhoneWidgetSnapshot? {
        guard let location, let data = try? Data(contentsOf: location) else { return nil }
        return try? JSONDecoder().decode(PhoneWidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: PhoneWidgetSnapshot) throws {
        guard let location else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static var location: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("phone-concentration-widget-v1.json", isDirectory: false)
    }
}
