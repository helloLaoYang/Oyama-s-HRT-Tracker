#if DEBUG && targetEnvironment(simulator)
import Foundation

extension WatchTrackerStore {
    static func demoSnapshot(at now: Date) -> WatchSnapshot {
        let expires = now.addingTimeInterval(12 * 3600)
        func series(_ metric: WatchMetric, _ values: [Double]) -> WatchConcentrationSeries {
            let points = values.enumerated().map { index, value in
                WatchConcentrationPoint(time: now.addingTimeInterval(Double(index - 8) * 3 * 3600), value: value)
            }
            return WatchConcentrationSeries(metric: metric, points: points)
        }
        let patch = WatchDoseOccurrence(id: "demo-patch", version: "demo", title: String(localized: "Replace estradiol patch"),
                                        detail: String(localized: "50 µg/day × 2 patches"), scheduledAt: now.addingTimeInterval(19 * 60),
                                        action: .replacePatch, completed: false)
        let cpa = WatchDoseOccurrence(id: "demo-cpa", version: "demo", title: String(localized: WatchMetric.cpa.title),
                                      detail: "6.25 mg", scheduledAt: now.addingTimeInterval(2 * 3600),
                                      action: .take, completed: false)
        return WatchSnapshot(generatedAt: now, expiresAt: expires, planValidUntil: expires, primaryMetric: .e2,
                             series: [
                                 series(.e2, [116, 111, 104, 103, 98, 114, 127, 133, 128, 126, 122, 116, 107]),
                                 series(.cpa, [6.2, 5.1, 4.4, 9.4, 8.4, 7.6, 7.1, 6.5, 6.1, 5.7, 5.3, 5, 4.7]),
                                 series(.testosterone, [921, 933, 951, 970, 1008, 1043, 1052, 1039, 1024, 1018, 1005, 992, 964]),
                             ], occurrences: [patch, cpa])
    }
}
#endif
