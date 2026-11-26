import Foundation
import HRTEngine
import SwiftData
import XCTest
@testable import HRTTracker

final class AIRecordCorrectionTests: XCTestCase {
    func testModelValueRequiresOneExactNumberAndNoOtherFields() {
        XCTAssertEqual(AIRecordCorrection.modelValue(#"{ "value": 62.5 }"#, matching: "改成 62.5", unit: "mg"), 62.5)
        XCTAssertEqual(AIRecordCorrection.modelValue(#"{"value":62.5}"#, matching: "Set it to 62,5", unit: "mg",
                                                     decimalSeparator: ","), 62.5)
        XCTAssertNil(AIRecordCorrection.modelValue(#"{"value":60}"#, matching: "改成 62.5", unit: "mg"))
        XCTAssertNil(AIRecordCorrection.modelValue(#"{"value":62.5}"#, matching: "Change 50 to 62.5", unit: "mg"))
        XCTAssertNil(AIRecordCorrection.modelValue(#"{"value":62.5}"#, matching: "Change to -62.5", unit: "mg"))
        XCTAssertNil(AIRecordCorrection.modelValue(#"{"value":62.5,"value":62.5}"#, matching: "62.5", unit: "mg"))
        XCTAssertNil(AIRecordCorrection.modelValue(#"{"value":62.5,"unit":"mg"}"#, matching: "62.5", unit: "mg"))
        XCTAssertNil(AIRecordCorrection.modelValue("```json\n{\"value\":62.5}\n```", matching: "62.5", unit: "mg"))
        XCTAssertNil(AIRecordCorrection.enteredValue("1,000"))
        XCTAssertNil(AIRecordCorrection.enteredValue("1.000", decimalSeparator: ","))
        XCTAssertEqual(AIRecordCorrection.enteredValue("1e-6"), 0.000001)
    }

    func testModelValueRejectsConflictingPatchUnitAndAcceptsEquivalentSpelling() {
        let reply = #"{"value":25}"#
        XCTAssertNil(AIRecordCorrection.modelValue(reply, matching: "改成 25 mg", unit: "µg/day per patch"))
        XCTAssertNil(AIRecordCorrection.modelValue(reply, matching: "改成 25 微克", unit: "µg/天／贴"))
        XCTAssertEqual(AIRecordCorrection.modelValue(reply, matching: "Set it to 25 MCG per day", unit: "µg/day per patch"), 25)
        XCTAssertEqual(AIRecordCorrection.modelValue(reply, matching: "改成 25 μg／天", unit: "µg/天／贴"), 25)
        XCTAssertEqual(AIRecordCorrection.modelValue(reply, matching: "改成 25", unit: "µg/天／贴"), 25)
    }

    func testDraftChangesOnlyPerPatchRateAndKeepsPatchMetadata() throws {
        let now = Date()
        let dose = DoseEvent(route: .patchApply, timeH: now.trackerHours - 1, doseMG: 0, ester: "E2",
                             extras: [HistoryText.rateKey: 100, HistoryText.countKey: 2, HistoryText.wearKey: 72])
        let record = AIRecordCorrection.Record.dose(dose)
        XCTAssertEqual(record.value, 50)
        XCTAssertNil(AIRecordCorrection(record: record, amount: 50, mode: .transfem, through: now))
        let correction = try XCTUnwrap(AIRecordCorrection(record: record, amount: 62.5, mode: .transfem, through: now))
        guard case .editDose(let original, let updated) = correction.change else {
            return XCTFail("Expected an edit to the selected dose")
        }
        var expected = dose
        expected.extras[HistoryText.rateKey] = 125
        XCTAssertEqual(original, dose)
        XCTAssertEqual(updated, expected)
    }

    @MainActor
    func testUndoAppliesOnlyWhileSavedVersionIsCurrent() throws {
        let schema = TrackerStore.schema
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let store = TrackerStore(context: container.mainContext)
        let lab = LabResult(timeH: store.nowH - 1, concValue: 80, unit: "pg/ml", assay: "lcms")
        XCTAssertTrue(store.saveLab(lab))
        let original = try XCTUnwrap(store.labs.first)

        func saveDraft(from record: LabResult) throws -> TrackerRecordChange {
            let draft = try XCTUnwrap(AIRecordCorrection(record: .lab(record), amount: 90,
                                                         mode: .transfem, through: store.now))
            XCTAssertEqual(store.labs.first?.concValue, record.concValue)
            XCTAssertEqual(store.applyRecordChange(draft.change, mode: .transfem), .saved)
            XCTAssertEqual(store.labs.first?.concValue, 90)
            return try XCTUnwrap(draft.undoAfterSave(in: store))
        }

        let undo = try saveDraft(from: original)
        XCTAssertEqual(store.applyRecordChange(undo, mode: .transfem), .saved)
        let restored = try XCTUnwrap(store.labs.first)
        XCTAssertEqual(restored.concValue, original.concValue)
        XCTAssertEqual(restored.assay, original.assay)
        XCTAssertEqual(restored.unit, original.unit)

        let staleUndo = try saveDraft(from: restored)
        var later = try XCTUnwrap(store.labs.first)
        later.concValue = 100
        XCTAssertTrue(store.saveLab(later))
        XCTAssertEqual(store.applyRecordChange(staleUndo, mode: .transfem), .conflict)
        XCTAssertEqual(store.labs.first?.concValue, 100)
    }
}
