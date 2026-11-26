import Foundation
import XCTest
@testable import HRTTracker

final class PhoneWidgetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testPhoneAndWatchSelectTheSameCurrentPointAndHistory() throws {
        let watch = sample()
        let phone = PhoneWidgetSnapshot(watch)

        XCTAssertEqual(phone.primaryMetric, watch.primaryMetric)
        for date in [now, now.addingTimeInterval(899), now.addingTimeInterval(900)] {
            for metric in WatchMetric.allCases {
                XCTAssertEqual(phone.current(for: metric, at: date), watch.current(for: metric, at: date))
                XCTAssertEqual(phone.history(for: metric, at: date), watch.history(for: metric, at: date))
            }
        }
        XCTAssertEqual(phone.current(for: .e2, at: now)?.value, 128)
        XCTAssertEqual(phone.history(for: .e2, at: now).map(\.value), [104, 128])
        XCTAssertNil(phone.current(for: .cpa, at: now))
    }

    func testSharedPayloadContainsOnlyConcentrationFieldsAndDropsExpiredEstimates() throws {
        let watch = sample()
        let data = try JSONEncoder().encode(PhoneWidgetSnapshot(watch))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["generatedAt", "expiresAt", "primaryMetric", "series"])

        let phone = try JSONDecoder().decode(PhoneWidgetSnapshot.self, from: data)
        XCTAssertEqual(phone.expiresAt, watch.expiresAt)
        XCTAssertEqual(phone.current(for: .e2, at: watch.expiresAt.addingTimeInterval(-1))?.value, 126)
        XCTAssertNil(phone.current(for: .e2, at: watch.expiresAt))
        XCTAssertTrue(phone.history(for: .e2, at: watch.expiresAt).isEmpty)
    }

    private func sample() -> WatchSnapshot {
        let points = [
            WatchConcentrationPoint(time: now.addingTimeInterval(-86_401), value: 103),
            WatchConcentrationPoint(time: now.addingTimeInterval(-86_400), value: 104),
            WatchConcentrationPoint(time: now, value: 128),
            WatchConcentrationPoint(time: now.addingTimeInterval(900), value: 126),
        ]
        return WatchSnapshot(generatedAt: now, expiresAt: now.addingTimeInterval(86_400),
                             planValidUntil: now.addingTimeInterval(3_600), primaryMetric: .e2,
                             series: [WatchConcentrationSeries(metric: .e2, points: points)], occurrences: [])
    }
}
