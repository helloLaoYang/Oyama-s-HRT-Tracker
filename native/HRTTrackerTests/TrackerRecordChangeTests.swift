import Foundation
import HRTEngine
import SwiftData
import XCTest
@testable import HRTTracker

final class TrackerRecordChangeTests: XCTestCase {
    @MainActor
    func testDoseCreateAndEditReplayOnlySaveOnce() throws {
        let (container, store) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let dose = DoseEvent(route: .oral, timeH: store.nowH - 1, doseMG: 1, ester: "E2")
        XCTAssertEqual(store.applyRecordChange(.addDose(dose), mode: .transfem), .saved)
        let original = try XCTUnwrap(store.doses.first)
        XCTAssertNotNil(original.updatedAt)
        XCTAssertEqual(store.applyRecordChange(.addDose(dose), mode: .transfem), .alreadySaved)

        var updated = original
        updated.timeH -= 1
        XCTAssertEqual(store.applyRecordChange(.addDose(updated), mode: .transfem), .conflict)
        let edit = TrackerRecordChange.editDose(original: original, updated: updated)
        XCTAssertEqual(store.applyRecordChange(edit, mode: .transfem), .saved)
        let saved = try XCTUnwrap(store.doses.first)
        XCTAssertEqual(saved.id, dose.id)
        XCTAssertEqual(saved.timeH, updated.timeH)
        XCTAssertEqual(store.applyRecordChange(edit, mode: .transfem), .alreadySaved)
        XCTAssertEqual(store.doses, [saved])
    }

    @MainActor
    func testStaleOrPlanLinkedDoseChangesLeaveRecordsIntact() throws {
        let (container, store) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let dose = DoseEvent(route: .oral, timeH: store.nowH - 1, doseMG: 1, ester: "E2")
        XCTAssertTrue(store.saveDose(dose))
        let original = try XCTUnwrap(store.doses.first)
        var edit = original
        edit.doseMG = 2

        var manual = original
        manual.timeH -= 1
        XCTAssertTrue(store.saveDose(manual))
        XCTAssertEqual(store.applyRecordChange(.editDose(original: original, updated: edit), mode: .transfem), .conflict)
        XCTAssertEqual(store.doses.first?.timeH, manual.timeH)
        XCTAssertEqual(store.doses.first?.doseMG, manual.doseMG)
        XCTAssertTrue(store.deleteDose(original.id))
        XCTAssertEqual(store.applyRecordChange(.editDose(original: original, updated: edit), mode: .transfem), .conflict)
        XCTAssertTrue(store.doses.isEmpty)

        let plan = MedicationPlan(route: .oral, ester: "E2", doseMG: 1)
        XCTAssertTrue(store.savePlan(plan))
        let completion = try XCTUnwrap(store.complete(plan))
        let originalCompletion = try XCTUnwrap(store.doses.first)
        var changedCompletion = originalCompletion
        changedCompletion.timeH -= 1
        let change = TrackerRecordChange.editDose(original: originalCompletion, updated: changedCompletion)
        XCTAssertEqual(store.applyRecordChange(change, mode: .transfem), .invalid)
        XCTAssertEqual(store.doses, [originalCompletion])
        XCTAssertEqual(completion.id, originalCompletion.id)
        XCTAssertEqual(store.planStatus(plan), .taken)
    }

    @MainActor
    func testInvalidPatchOrFutureDoseCannotBeInserted() throws {
        let (container, store) = try makeStore(demo: true)
        defer { withExtendedLifetime(container) {} }
        let baseline = store.doses
        let patch = try XCTUnwrap(TrackerRecordValidation.patchDose(perPatch: 50, count: 2, isReleaseRate: true))
        var dose = DoseEvent(route: .patchApply, timeH: store.nowH + 1, doseMG: patch.amount,
                             ester: "E2", extras: patch.extras)
        XCTAssertEqual(store.applyRecordChange(.addDose(dose), mode: .transfem), .invalid)
        dose.timeH = store.nowH - 1
        XCTAssertEqual(store.applyRecordChange(.addDose(dose), mode: .transmasc), .conflict)
        dose.ester = "CPA"
        XCTAssertEqual(store.applyRecordChange(.addDose(dose), mode: .transfem), .invalid)
        dose.ester = "E2"
        dose.doseMG = 1
        XCTAssertEqual(store.applyRecordChange(.addDose(dose), mode: .transfem), .invalid)
        dose.doseMG = patch.amount
        dose.extras[HistoryText.countKey] = 2.5
        XCTAssertEqual(store.applyRecordChange(.addDose(dose), mode: .transfem), .invalid)
        XCTAssertEqual(store.doses, baseline)

        dose.extras = patch.extras
        XCTAssertEqual(store.applyRecordChange(.addDose(dose), mode: .transfem), .saved)
        let saved = try XCTUnwrap(store.doses.first { $0.id == dose.id })
        XCTAssertEqual(saved.doseMG, 0)
        XCTAssertEqual(saved.extras[HistoryText.countKey], 2)
        XCTAssertEqual(saved.extras[HistoryText.rateKey], 100)
    }

    @MainActor
    func testLabUnitIsNormalizedAndOnlyValidEditIsPersisted() throws {
        let (container, store) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let lab = LabResult(timeH: store.nowH - 1, concValue: 90, unit: "pg/mL")
        XCTAssertEqual(store.applyRecordChange(.addLab(lab), mode: .transfem), .saved)
        let original = try XCTUnwrap(store.labs.first)
        XCTAssertEqual(original.unit, "pg/ml")
        XCTAssertEqual(store.applyRecordChange(.addLab(lab), mode: .transfem), .alreadySaved)

        var edit = original
        edit.concValue = .infinity
        XCTAssertEqual(store.applyRecordChange(.editLab(original: original, updated: edit), mode: .transfem), .invalid)
        edit.concValue = 110
        edit.unit = "ng/dl"
        XCTAssertEqual(store.applyRecordChange(.editLab(original: original, updated: edit), mode: .transfem), .invalid)
        edit.unit = original.unit
        edit.id = UUID().uuidString
        XCTAssertEqual(store.applyRecordChange(.editLab(original: original, updated: edit), mode: .transfem), .invalid)
        XCTAssertEqual(store.labs, [original])

        edit.id = original.id
        let change = TrackerRecordChange.editLab(original: original, updated: edit)
        XCTAssertEqual(store.applyRecordChange(change, mode: .transfem), .saved)
        XCTAssertEqual(store.applyRecordChange(change, mode: .transfem), .alreadySaved)
        XCTAssertEqual(store.labs.count, 1)
        XCTAssertEqual(store.labs.first?.id, original.id)
        XCTAssertEqual(store.labs.first?.concValue, 110)
    }

    @MainActor
    private func makeStore(demo: Bool = false) throws -> (ModelContainer, TrackerStore) {
        let schema = TrackerStore.schema
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        return (container, TrackerStore(context: container.mainContext, demo: demo))
    }
}
