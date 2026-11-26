import HRTEngine
import XCTest
@testable import HRTTracker

final class AIRecordRetrievalTests: XCTestCase {
    func testBilingualRouteSearchFindsAnOlderSourceAndKeepsSummaryFacts() throws {
        let latest = DoseEvent(id: "latest-oral", route: .oral, timeH: try date(25).trackerHours,
                               doseMG: 2, ester: "E2")
        let patch = DoseEvent(id: "older-patch", route: .patchApply, timeH: try date(20).trackerHours,
                              doseMG: 2, ester: "E2")
        let summary = [
            AIInsightFact(id: "dose-count", text: "Dose count", source: nil),
            AIInsightFact(id: "latest-dose", text: "Latest dose", source: .dose(latest.id)),
            AIInsightFact(id: "estimate-e2", text: "Model estimate", source: .curve),
            AIInsightFact(id: "estimate-explanation", text: "Measured versus estimated", source: nil),
        ]
        let snapshot = try makeSnapshot(doses: [latest, patch], facts: summary)

        for question in ["What was my patch dose?", "我的贴片剂量是多少？"] {
            let result = snapshot.facts(matching: question)
            XCTAssertEqual(result.first?.source, .dose(patch.id))
            XCTAssertTrue(summary.allSatisfy(result.contains))
            XCTAssertEqual(result.filter { $0.source == .dose(latest.id) }.count, 1)
        }
        XCTAssertEqual(snapshot.facts(matching: "Hello"), summary)
    }

    func testExactDateFindsALabOnTheCapturedLocalDayAndHonorsTheRange() throws {
        let requested = LabResult(id: "correct-day", timeH: try date(20, hour: 1).trackerHours,
                                  concValue: 120, unit: "pg/ml")
        let previous = LabResult(id: "same-utc-day", timeH: try date(19, hour: 23).trackerHours,
                                 concValue: 150, unit: "pg/ml")
        let outside = LabResult(id: "outside", timeH: try date(4).trackerHours,
                                concValue: 195, unit: "pg/ml")
        let snapshot = try makeSnapshot(labs: [requested, previous, outside])

        for question in ["2026-11-20 lab result", "11月20日的化验结果"] {
            XCTAssertEqual(snapshot.facts(matching: question).compactMap(\.source), [.lab(requested.id)])
        }
        let missed = snapshot.facts(matching: "2026年11月4日的化验结果")
        XCTAssertEqual(missed.map(\.id), ["no-matching-date-records"])
    }

    func testDateMissDoesNotReturnAnUnrelatedLatestRecordOrEstimate() throws {
        let latest = LabResult(id: "latest-lab-id", timeH: try date(25).trackerHours, concValue: 160, unit: "pg/ml")
        let count = AIInsightFact(id: "lab-count", text: "One result during this period", source: nil)
        let summary = [
            count,
            AIInsightFact(id: "latest-lab", text: "Latest lab measurement", source: .lab(latest.id)),
            AIInsightFact(id: "estimate-e2", text: "Current estimate", source: .curve),
        ]
        let snapshot = try makeSnapshot(labs: [latest], facts: summary)

        let result = snapshot.facts(matching: "Lab on 2026-11-20")

        XCTAssertEqual(result.map(\.id), ["no-matching-date-records", count.id])
        XCTAssertTrue(result.compactMap(\.source).isEmpty)
    }

    func testGenericMatchingTopicKeepsOnlyTheSixMostRecentCandidates() throws {
        let doses = try (16...25).reversed().map { day in
            DoseEvent(id: "dose-\(day)", route: .oral, timeH: try date(day).trackerHours, doseMG: 2, ester: "E2")
        }
        let snapshot = try makeSnapshot(doses: doses)

        let expected = doses.prefix(6).map { AIRecordReference.dose($0.id) }
        XCTAssertEqual(snapshot.facts(matching: "Recent medication records").compactMap(\.source), expected)
    }

    private func makeSnapshot(doses: [DoseEvent] = [], labs: [LabResult] = [],
                              facts: [AIInsightFact] = []) throws -> AIInsightSnapshot {
        let start = try date(15)
        let end = try date(26)
        return AIInsightSnapshot(mode: .transfem, range: .month, facts: facts, doses: doses, labs: labs,
                                 capturedInterval: start...end, capturedTimeZoneID: "Asia/Shanghai")
    }

    private func date(_ day: Int, hour: Int = 0) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        return try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour)))
    }
}
