import Foundation
import HRTEngine
import XCTest
@testable import HRTTracker

final class AIRecordChangeDraftTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testConflictingOrAmbiguousTargetRequiresLocalSelection() throws {
        // These two measurements fall in the same local minute.
        let first = LabResult(id: "first", timeH: (now - 18).trackerHours, concValue: 80, unit: "pg/ml")
        let second = LabResult(id: "second", timeH: (now - 17).trackerHours, concValue: 85, unit: "pg/ml")
        let snapshot = snapshot(labs: [first, second])
        var ambiguous = try draft(#"{"operation":"edit_lab","target_at":"2023-11-15T06:13+08:00","amount":90,"unit":"pg/ml"}"#,
                                  snapshot: snapshot)
        XCTAssertNil(ambiguous.selected)
        XCTAssertNil(ambiguous.change(parameters: PKParameters(), now: now))

        let conflicting = try draft(#"{"operation":"edit_lab","record_ref":"fact-1","target_at":"2023-11-15T05:12+08:00"}"#,
                                    snapshot: snapshot, reference: .lab(first.id))
        XCTAssertNil(conflicting.selected)

        ambiguous.select(ambiguous.candidates[1].id)
        guard case .editLab(let original, let updated) = ambiguous.change(parameters: PKParameters(), now: now) else {
            return XCTFail("An explicit selection should create a draft update.")
        }
        XCTAssertEqual(original, second)
        XCTAssertEqual(updated.id, second.id)
        XCTAssertEqual(updated.timeH, second.timeH)
        XCTAssertEqual(updated.concValue, 90)
    }

    func testNewMeasurementNeedsAnExplicitUnitAndHistoricalZonedDate() throws {
        var proposed = try draft(#"{"operation":"add_lab","occurred_at":"2023-11-15T06:12:00+08:00","analyte":"estradiol","amount":90}"#,
                                 snapshot: snapshot())
        XCTAssertEqual(proposed.time, now - 80)
        XCTAssertNil(proposed.change(parameters: PKParameters(), now: now))
        proposed.chooseUnit("pg/ml")

        guard case .addLab(let first) = proposed.change(parameters: PKParameters(), now: now),
              case .addLab(let retry) = proposed.change(parameters: PKParameters(), now: now) else {
            return XCTFail("A complete measurement should have a saveable draft.")
        }
        XCTAssertEqual(first, retry)
        XCTAssertNotNil(UUID(uuidString: first.id))
        XCTAssertEqual(first.concValue, 90)

        let invalidTimestamp = try draft(#"{"operation":"add_lab","occurred_at":"2023-11-15T06:12:00","analyte":"estradiol","amount":90,"unit":"pg/ml"}"#,
                                         snapshot: snapshot())
        XCTAssertNil(invalidTimestamp.time)
        XCTAssertNil(invalidTimestamp.change(parameters: PKParameters(), now: now))

        let invalidAnalyte = try draft(#"{"operation":"add_lab","occurred_at":"2023-11-15T06:12:00+08:00","analyte":"total_testosterone","amount":90,"unit":"pg/ml"}"#,
                                       snapshot: snapshot())
        XCTAssertTrue(invalidAnalyte.analyteMismatch)
        XCTAssertNil(invalidAnalyte.change(parameters: PKParameters(), now: now))
    }

    func testEquivalentPatchDraftPreservesStoredDetailsAndExcludesPlanRecords() throws {
        let patch = DoseEvent(id: "manual", route: .patchApply, timeH: now.trackerHours - 1, doseMG: 0, ester: "E2",
                              extras: [HistoryText.rateKey: 100, HistoryText.countKey: 2, HistoryText.wearKey: 48])
        let plan = DoseEvent(id: "hrt-plan-example", route: .oral, timeH: now.trackerHours - 1, doseMG: 2, ester: "E2")
        let proposed = try draft(#"{"operation":"edit_dose","record_ref":"fact-1","occurred_at":"2023-11-15T06:12:00+08:00"}"#,
                                 snapshot: snapshot(doses: [patch, plan]), reference: .dose(patch.id))
        XCTAssertEqual(proposed.candidates.map(\.reference), [.dose(patch.id)])
        guard case .editDose(let original, let updated) = proposed.change(parameters: PKParameters(), now: now) else {
            return XCTFail("A historical time correction should preserve the dose.")
        }
        XCTAssertEqual(original, patch)
        XCTAssertEqual(updated.extras, original.extras)
        XCTAssertEqual(updated.doseMG, original.doseMG)
    }

    private func snapshot(doses: [DoseEvent] = [], labs: [LabResult] = []) -> AIInsightSnapshot {
        AIInsightSnapshot(mode: .transfem, range: .month, facts: [], doses: doses, labs: labs,
                          capturedInterval: (now - 86400)...now)
    }

    private func draft(_ json: String, snapshot: AIInsightSnapshot, reference: AIRecordReference? = nil) throws
        -> AIRecordChangeDraft {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let arguments = try JSONDecoder().decode(AIRecordChangeArguments.self, from: Data(json.utf8))
        return AIRecordChangeDraft(arguments: arguments, snapshot: snapshot, reference: reference, calendar: calendar)
    }
}
