import Foundation
import HRTEngine
import SwiftData
import XCTest
@testable import HRTTracker

final class InventoryCostTests: XCTestCase {
    @MainActor
    func testStoreKeepsDoseBindingsAndHistoricalCostsAfterRepricingAndArchiving() throws {
        let config = ModelConfiguration(schema: TrackerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TrackerStore.schema, configurations: [config])
        let store = TrackerStore(context: container.mainContext, demo: false)
        let now = store.nowH
        var first = MedicationSupply(id: "first", route: .oral, ester: "E2", pack: .pill(mg: 2),
                                     count: 18, startedAt: (now - 24) * 3_600_000)
        XCTAssertTrue(store.saveSupply(first))
        let half = DoseEvent(id: "half", route: .oral, timeH: now - 2, doseMG: 1, ester: "E2")
        XCTAssertTrue(store.saveDose(half))
        XCTAssertEqual(store.doses.first?.inventorySupplyId, first.id)

        var second = MedicationSupply(id: "second", route: .oral, ester: "E2", pack: .pill(mg: 1),
                                      count: 10, startedAt: first.startedAt)
        second.purchase = StockPurchase(unitsPerPack: 10, packCount: 1, totalMinor: 1500, currency: .CNY)
        XCTAssertTrue(store.saveSupply(second))
        var whole = DoseEvent(id: "whole", route: .oral, timeH: now - 1, doseMG: 1, ester: "E2")
        XCTAssertTrue(store.saveDose(whole))
        let unconfirmed = try XCTUnwrap(InventoryLedger(supplies: store.supplies, events: store.doses, nowH: now).uses.last)
        XCTAssertTrue(unconfirmed.needsSpecification)
        whole.inventorySupplyId = second.id
        XCTAssertTrue(store.saveDose(whole))
        first.purchase = StockPurchase(unitsPerPack: 28, packCount: 1, totalMinor: 5600, currency: .CNY)
        XCTAssertTrue(store.saveSupply(first))
        XCTAssertTrue(store.deleteSupply(first.id))
        let reopened = TrackerStore(context: ModelContext(container), demo: false)
        let snapshot = InventorySnapshot(store: reopened)
        XCTAssertEqual(snapshot.statuses.map(\.id), [second.id])
        XCTAssertEqual(stockCostTotals(snapshot.ledger.uses.flatMap(\.parts)), [.CNY: 2.5])
        XCTAssertEqual(snapshot.ledger.remaining[first.id], 35)
        XCTAssertEqual(snapshot.ledger.remaining[second.id], 9)
    }

    func testPricesAndStrengthsRequireAWholeLocalizedNumber() {
        let locale = Locale(identifier: "de_DE")
        XCTAssertEqual(stockInputNumber("12,50", locale: locale), 12.5)
        XCTAssertNil(stockInputNumber("12.56.25", locale: Locale(identifier: "zh_CN")))
        XCTAssertNil(stockInputNumber("56xyz", locale: locale))
        XCTAssertNil(StockPurchase.minorAmount("0,000000001", currency: .CNY, locale: locale))
        XCTAssertEqual(StockPurchase.minorAmount("12,50", currency: .CNY, locale: locale), 1250)
    }

    func testWebBackupAndNativeRoundTripUseTheSameStock() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "medication-cost-backup", withExtension: "json"))
        let incoming = try TrackerBackup.read(Data(contentsOf: url), fallbackMode: .transfem, currentYear: 2026)
        let exported = try TrackerBackup.write(incoming, at: Date())
        let attachment = XCTAttachment(data: exported, uniformTypeIdentifier: "public.json")
        attachment.name = "native-inventory-backup"
        attachment.lifetime = .keepAlways
        add(attachment)
        let restored = try TrackerBackup.read(exported, fallbackMode: .transfem, currentYear: 2026)
        for backup in [incoming, restored] {
            XCTAssertEqual(backup.invalid, 0)
            let records = try XCTUnwrap(backup.modes[.transfem])
            let lots = records.supplies.map(\.value)
            let ledger = InventoryLedger(supplies: lots, events: records.doses, nowH: 480010)
            let uses = Dictionary(uniqueKeysWithValues: ledger.uses.map { ($0.id, $0) })
            XCTAssertEqual(uses["cross-batch"]?.parts.map(\.cost), [2, 3])
            XCTAssertEqual(uses["half-tablet"]?.parts.first?.units, 0.5)
            XCTAssertEqual(uses["whole-tablet"]?.parts.first?.units, 1)
            XCTAssertEqual(stockCostTotals(ledger.uses.flatMap(\.parts)), [.CNY: 8])
            XCTAssertEqual(uses["ambiguous"]?.needsSpecification, true)
            XCTAssertEqual(uses["two-patches"]?.complete, false)
            XCTAssertNil(uses["remove"])
            XCTAssertNil(uses["future"])
            XCTAssertEqual(ledger.remaining, ["older": 0, "newer": 4, "other-strength": 3, "patches": 6])
            var priced = lots
            let index = try XCTUnwrap(priced.firstIndex { $0.id == "patches" })
            priced[index].purchase = StockPurchase(unitsPerPack: 8, packCount: 1, totalMinor: 0, currency: .JPY)
            let revised = InventoryLedger(supplies: priced, events: records.doses, nowH: 480010)
            XCTAssertEqual(revised.remaining, ledger.remaining)
            XCTAssertEqual(stockCostTotals(revised.uses.flatMap(\.parts)), [.CNY: 8, .JPY: 0])
        }
    }

    func testPeriodStartsUseLocalCalendarDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        for (range, month, day) in [(MedicationCostRange.today, 3, 10), (.last7, 3, 4), (.last30, 2, 9)] {
            let start = try XCTUnwrap(range.start(now: now, calendar: calendar))
            XCTAssertEqual(calendar.component(.month, from: start), month)
            XCTAssertEqual(calendar.component(.day, from: start), day)
            XCTAssertEqual(calendar.component(.hour, from: start), 0)
        }
        XCTAssertNil(MedicationCostRange.all.start(now: now, calendar: calendar))
    }
}
