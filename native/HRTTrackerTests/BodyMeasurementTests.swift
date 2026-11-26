import Foundation
import SwiftData
import XCTest
@testable import HRTTracker

final class BodyMeasurementTests: XCTestCase {
    @MainActor
    func testLatestUsesMeasurementTimeAndRevisionsPersistAcrossModes() throws {
        let container = try memoryContainer()
        let store = TrackerStore(context: container.mainContext)
        let recent = Date(timeIntervalSince1970: 1_790_000_000)
        let previous = recent.addingTimeInterval(-86_400)
        let older = previous.addingTimeInterval(-86_400)

        XCTAssertTrue(store.saveBodyMeasurements([.waist: 74, .weight: 64.75], measuredAt: previous))
        let original = try XCTUnwrap(store.latestBodyMeasurement(.waist))
        XCTAssertTrue(store.saveBodyMeasurements([.waist: 75], measuredAt: recent))
        let sameTimeFirst = try XCTUnwrap(store.latestBodyMeasurement(.waist))
        XCTAssertTrue(store.saveBodyMeasurements([.waist: 76], measuredAt: recent))
        let latest = try XCTUnwrap(store.latestBodyMeasurement(.waist))
        let firstRevision = try XCTUnwrap(latest.current)
        XCTAssertNotEqual(sameTimeFirst.id, latest.id)

        XCTAssertTrue(store.saveBodyMeasurements([.waist: 79], measuredAt: older))
        XCTAssertTrue(store.reviseBodyMeasurement(original.id, value: 73, measuredAt: previous))
        XCTAssertEqual(store.latestBodyMeasurement(.waist)?.id, latest.id)
        XCTAssertTrue(store.reviseBodyMeasurement(latest.id, value: 78, measuredAt: older))
        XCTAssertEqual(store.latestBodyMeasurement(.waist)?.id, sameTimeFirst.id)

        XCTAssertTrue(store.restoreBodyMeasurement(latest.id, revisionID: firstRevision.id))
        XCTAssertEqual(store.latestBodyMeasurement(.waist)?.revisions.map(\.value), [76, 78, 76])
        XCTAssertTrue(store.deleteBodyMeasurement(latest.id))
        XCTAssertEqual(store.latestBodyMeasurement(.waist)?.id, sameTimeFirst.id)

        store.mode = .transmasc
        XCTAssertEqual(store.weight, 64.75)
        let reopened = TrackerStore(context: ModelContext(container))
        XCTAssertEqual(reopened.latestBodyMeasurement(.waist)?.id, sameTimeFirst.id)
        XCTAssertEqual(reopened.bodyMeasurements(for: .waist).first { $0.id == original.id }?.revisions.map(\.value), [74, 73])
        XCTAssertEqual(reopened.latestBodyMeasurement(.weight)?.current?.value, 64.75)
        XCTAssertNil(reopened.latestBodyMeasurement(.height))
    }

    @MainActor
    func testLegacyWeightWithUnknownMeasurementTimeMigratesOnce() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let profile = TrackerProfileRecord()
        profile.weight = 64.75
        profile.weightUpdatedAt = 1_790_000_000_000
        context.insert(profile)
        try context.save()

        let store = TrackerStore(context: context)
        let legacy = try XCTUnwrap(store.latestBodyMeasurement(.weight))
        XCTAssertNil(legacy.current?.measuredAt)
        XCTAssertEqual(store.weight, 64.75)
        XCTAssertTrue(store.saveBodyMeasurements([.weight: 66], measuredAt: Date(timeIntervalSince1970: 1_750_000_000)))
        let measured = try XCTUnwrap(store.latestBodyMeasurement(.weight))
        XCTAssertNotEqual(measured.id, legacy.id)
        XCTAssertEqual(store.weight, 66)
        XCTAssertTrue(store.deleteBodyMeasurement(measured.id))
        XCTAssertEqual(store.weight, 64.75)
        XCTAssertTrue(store.deleteBodyMeasurement(legacy.id))

        let reopened = TrackerStore(context: ModelContext(container))
        XCTAssertTrue(reopened.bodyMeasurements(for: .weight).isEmpty)
        XCTAssertEqual(reopened.weight, 70)
    }

    @MainActor
    func testBackupPreservesDistinctRevisionsAndReimportIsIdempotent() throws {
        let sourceContainer = try memoryContainer()
        let receiverContainer = try memoryContainer()
        let source = TrackerStore(context: sourceContainer.mainContext)
        let receiver = TrackerStore(context: receiverContainer.mainContext)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(source.saveBodyMeasurements([.upperArm: 25], measuredAt: date))
        let measured = try XCTUnwrap(source.latestBodyMeasurement(.upperArm))
        let backup = try source.exportBackup()
        XCTAssertEqual(try receiver.importBackup(receiver.previewBackup(backup)).added, 1)
        XCTAssertTrue(source.reviseBodyMeasurement(measured.id, value: 26, measuredAt: date))
        XCTAssertTrue(receiver.reviseBodyMeasurement(measured.id, value: 27, measuredAt: date))
        let forkedBackup = try receiver.exportBackup()

        let preview = try source.previewBackup(forkedBackup)
        XCTAssertEqual(preview.updated, 1)
        XCTAssertEqual(source.latestBodyMeasurement(.upperArm)?.revisions.count, 2)
        XCTAssertEqual(try source.importBackup(preview).updated, 1)
        let merged = try XCTUnwrap(source.latestBodyMeasurement(.upperArm))
        XCTAssertEqual(Set(merged.revisions.map(\.value)), [25, 26, 27])
        XCTAssertEqual(merged.revisions.first?.measuredAt, date)
        XCTAssertEqual(Set(merged.revisions.map(\.id)).count, 3)
        XCTAssertEqual(try source.importBackup(source.previewBackup(forkedBackup)).skipped, 1)
        XCTAssertEqual(source.latestBodyMeasurement(.upperArm), merged)
    }

    @MainActor
    func testOldBackupsOnlyMigrateAnExplicitWeight() throws {
        let container = try memoryContainer()
        let store = TrackerStore(context: container.mainContext)
        XCTAssertNil(store.latestBodyMeasurement(.weight))
        XCTAssertEqual(store.weight, 70)

        var oldBackup = BackupContents()
        oldBackup.weight = 70
        let defaultOnly = try TrackerBackup.write(oldBackup, at: Date())
        XCTAssertEqual(try store.importBackup(store.previewBackup(defaultOnly)).added, 0)
        XCTAssertNil(store.latestBodyMeasurement(.weight))

        oldBackup.weightUpdatedAt = 1_790_000_000_000
        let explicit = try TrackerBackup.write(oldBackup, at: Date())
        XCTAssertEqual(try store.importBackup(store.previewBackup(explicit)).added, 1)
        XCTAssertEqual(try store.importBackup(store.previewBackup(explicit)).skipped, 1)
        XCTAssertEqual(store.latestBodyMeasurement(.weight)?.current?.value, 70)
        XCTAssertNil(store.latestBodyMeasurement(.weight)?.current?.measuredAt)

        oldBackup.weight = 62
        oldBackup.weightUpdatedAt = nil
        let unstamped = try TrackerBackup.write(oldBackup, at: Date())
        XCTAssertEqual(try store.importBackup(store.previewBackup(unstamped)).added, 0)
        XCTAssertEqual(store.bodyMeasurements(for: .weight).count, 1)
        XCTAssertEqual(store.weight, 70)

        let record = try XCTUnwrap(store.latestBodyMeasurement(.weight))
        XCTAssertTrue(store.deleteBodyMeasurement(record.id))
        let newBackup = try store.exportBackup()
        XCTAssertEqual(try store.importBackup(store.previewBackup(newBackup)).added, 0)
        XCTAssertNil(store.latestBodyMeasurement(.weight))
    }

    func testLargeBodyHistoryDoesNotConsumeTheModeRecordLimit() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let revision = BodyMeasurementRevision(id: "original", value: 174, measuredAt: date, savedAt: date)
        var backup = BackupContents()
        backup.bodyMeasurements = (0...20_000).map {
            BodyMeasurement(id: String($0), metric: .height, revisions: [revision])
        }
        let data = try TrackerBackup.write(backup, at: date)
        let decoded = try TrackerBackup.read(data, fallbackMode: .transfem, currentYear: 2026)
        XCTAssertEqual(decoded.bodyMeasurements?.count, 20_001)
        XCTAssertEqual(decoded.invalid, 0)
    }

    @MainActor
    func testInvalidBatchesAndBackupDatesDoNotChangeMeasurements() throws {
        let container = try memoryContainer()
        let store = TrackerStore(context: container.mainContext)
        XCTAssertFalse(store.saveBodyMeasurements([:], measuredAt: store.now))
        XCTAssertFalse(store.saveBodyMeasurements([.height: 174, .weight: .infinity], measuredAt: store.now))
        let tomorrow = store.now.addingTimeInterval(86_400)
        XCTAssertFalse(store.saveBodyMeasurements([.height: 174], measuredAt: tomorrow))
        XCTAssertTrue(store.bodyMeasurements(for: .height).isEmpty)

        var backup = BackupContents()
        backup.bodyMeasurements = [
            BodyMeasurement(metric: .height, value: 174, measuredAt: store.now, savedAt: tomorrow)
        ]
        let data = try TrackerBackup.write(backup, at: store.now)
        let preview = try store.previewBackup(data)
        XCTAssertEqual(preview.invalid, 1)
        XCTAssertEqual(try store.importBackup(preview).added, 0)
        XCTAssertTrue(store.bodyMeasurements(for: .height).isEmpty)
    }

    @MainActor
    private func memoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: TrackerStore.schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: TrackerStore.schema, configurations: [config])
    }
}
