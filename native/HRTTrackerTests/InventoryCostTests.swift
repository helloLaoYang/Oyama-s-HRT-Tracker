import Foundation
import HRTEngine
import SwiftData
import XCTest
@testable import HRTTracker

final class InventoryCostTests: XCTestCase {
    func testPatchMatchesRecordedRatePerPatchAndTabletsCanShareConfirmedStock() throws {
        func patches(_ rate: Double) -> MedicationSupply {
            var lot = MedicationSupply(id: "patch-\(Int(rate))", route: .patchApply, ester: "E2", pack: .patch(rate: rate), count: 10, startedAt: 0)
            lot.purchase = StockPurchase(unitsPerPack: 10, packCount: 1, totalMinor: 8000, currency: .CNY)
            return lot
        }
        let fifty = patches(50), hundred = patches(100)
        let plan = MedicationPlan(route: .patchApply, ester: "E2", doseMG: 0, extras: ["releaseRateUGPerDay": 100, "patchCount": 2])
        let event = DoseEvent(id: "change", route: plan.route, timeH: 1, doseMG: 0, ester: plan.ester, extras: plan.extras)
        let stock = [hundred, fifty]
        let use = try XCTUnwrap(InventoryLedger(supplies: stock, events: [event], nowH: 2).uses.first)
        XCTAssertTrue(use.complete)
        XCTAssertEqual(use.parts.map(\.supply.id), [fifty.id])
        XCTAssertEqual(use.parts.first?.units, 2)
        XCTAssertEqual(use.parts.first?.cost, 16)
        XCTAssertEqual(InventorySpecifications(stock).selected(plan)?.id, fifty.id)
        let previous = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.preferenceKey) }
        for (language, unit) in [("en", "µg/day"), ("zh-Hans", "µg/天"), ("ja", "µg/日"), ("de", "µg/Tag"), ("fr", "µg/jour")] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            XCTAssertEqual(packageDetail(fifty.pack), "50 " + unit)
            XCTAssertTrue(planDoseCaption(plan).contains("50 " + unit))
            XCTAssertTrue(HistoryText.doseDescription(event).contains("50 " + unit))
        }
        XCTAssertTrue(InventoryLedger(supplies: [hundred], events: [event], nowH: 2).uses[0].missingStock)

        var tablet = MedicationSupply(id: "tablet", route: .oral, ester: "EV", pack: .pill(mg: 2), count: 8, startedAt: 0)
        tablet.purchase = StockPurchase(unitsPerPack: 8, packCount: 1, totalMinor: 1600, currency: .CNY)
        var sublingual = DoseEvent(id: "tablet-use", route: .sublingual, timeH: 1, doseMG: 1, ester: "EV")
        XCTAssertTrue(InventoryLedger(supplies: [tablet], events: [sublingual], nowH: 2).uses[0].needsSpecification)
        sublingual.inventorySupplyId = tablet.id
        let linked = try XCTUnwrap(InventoryLedger.preview(sublingual, supplies: [tablet], events: []))
        XCTAssertEqual(linked.dose.route, .sublingual)
        XCTAssertEqual(linked.parts.first?.cost, 1)
    }

    @MainActor
    func testPlanUsesItsSpecificationForPhoneWatchStockAndCost() throws {
        let config = ModelConfiguration(schema: TrackerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TrackerStore.schema, configurations: [config])
        let store = TrackerStore(context: container.mainContext)
        let start = (store.nowH - 24) * 3_600_000
        let one = MedicationSupply(id: "one", route: .oral, ester: "E2", pack: .pill(mg: 1), count: 28, startedAt: start)
        var two = MedicationSupply(id: "two", route: .oral, ester: "E2", pack: .pill(mg: 2), count: 2, startedAt: start)
        two.purchase = StockPurchase(unitsPerPack: 28, packCount: 1, totalMinor: 5600, currency: .CNY)
        XCTAssertTrue(store.saveSupply(one))
        XCTAssertTrue(store.saveSupply(two))
        let plan = MedicationPlan(route: .oral, ester: "E2", doseMG: 1, inventorySupplyId: two.id)
        XCTAssertTrue(store.savePlan(plan))
        let reopened = TrackerStore(context: ModelContext(container))
        let saved = try XCTUnwrap(reopened.plans.first)
        XCTAssertEqual(saved.inventorySupplyId, two.id)
        XCTAssertEqual(reopened.plannedStock(route: .oral, ester: "E2"), two.id)
        let before = InventorySnapshot(store: reopened)
        XCTAssertTrue(before.ledger.uses.isEmpty)
        XCTAssertEqual(before.statuses.first { $0.id == two.id }?.remainingUnits, 2)
        XCTAssertNil(before.statuses.first { $0.id == one.id }?.dailyUse)
        XCTAssertEqual(before.combinedStatuses.filter { $0.isLow(leadDays: 7, nowH: reopened.nowH) }.map(\.id), [two.id])

        let dose = try XCTUnwrap(reopened.complete(saved))
        XCTAssertNil(reopened.complete(saved))
        XCTAssertEqual(dose.inventorySupplyId, two.id)
        let logged = InventorySnapshot(store: reopened)
        XCTAssertEqual(logged.statuses.first { $0.id == one.id }?.remainingUnits, 28)
        XCTAssertEqual(logged.statuses.first { $0.id == two.id }?.remainingUnits, 1.5)
        XCTAssertEqual(stockCostTotals(logged.ledger.uses.flatMap(\.parts)), [.CNY: 1])
        XCTAssertTrue(reopened.deleteDose(dose.id))
        let undone = InventorySnapshot(store: reopened)
        XCTAssertEqual(undone.ledger.remaining, before.ledger.remaining)
        XCTAssertTrue(undone.ledger.uses.isEmpty)

        XCTAssertTrue(reopened.deleteSupply(two.id))
        XCTAssertNotNil(reopened.supplies.first { $0.id == two.id }?.archivedAt)
        var refill = two
        refill.id = "refill"
        XCTAssertTrue(reopened.saveSupply(refill))
        let slot = try XCTUnwrap(reopened.watchPlanOccurrences(at: reopened.now).first)
        let command = WatchDoseCommand(id: UUID(), occurrenceID: slot.id, version: slot.version, recordedAt: Date())
        XCTAssertEqual(reopened.recordWatchDose(command), .recorded)
        XCTAssertEqual(reopened.recordWatchDose(command), .alreadyRecorded)
        let use = try XCTUnwrap(InventorySnapshot(store: reopened).ledger.uses.first)
        XCTAssertEqual(use.dose.inventorySupplyId, two.id)
        XCTAssertEqual(use.parts.map(\.supply.id), [refill.id])
        XCTAssertEqual(use.parts.first?.cost, 1)
    }

    @MainActor
    func testCorrectingAPurchaseDatePricesAnEarlierDoseAndKeepsIndependentBatches() throws {
        let config = ModelConfiguration(schema: TrackerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TrackerStore.schema, configurations: [config])
        let store = TrackerStore(context: container.mainContext)
        let now = store.nowH
        func milliseconds(hoursAgo: Double) -> Double { (now - hoursAgo) * 3_600_000 }
        func purchase(id: String, rate: Double, count: Double, hoursAgo: Double, totalMinor: Int) -> MedicationSupply {
            var lot = MedicationSupply(id: id, route: .patchApply, ester: "E2", pack: .patch(rate: rate),
                                        count: count, startedAt: milliseconds(hoursAgo: hoursAgo))
            lot.purchase = StockPurchase(unitsPerPack: count, packCount: 1, totalMinor: totalMinor, currency: .CNY)
            return lot
        }

        let earlierDose = DoseEvent(id: "earlier-dose", route: .patchApply, timeH: now - 20, doseMG: 0, ester: "E2",
                                    extras: ["releaseRateUGPerDay": 37.5])
        let wrongStrength = purchase(id: "other-strength", rate: 25, count: 6, hoursAgo: 14, totalMinor: 1200)
        XCTAssertTrue(store.saveSupply(wrongStrength))
        XCTAssertTrue(store.saveDose(earlierDose))
        let unmatched = try XCTUnwrap(InventorySnapshot(store: store).ledger.uses.first)
        XCTAssertTrue(unmatched.missingStock)
        XCTAssertTrue(unmatched.parts.isEmpty)

        var first = purchase(id: "first-purchase", rate: 37.5, count: 2, hoursAgo: 12, totalMinor: 600)
        first.recounts = [StockRecount(at: milliseconds(hoursAgo: 1), count: 1)]
        let second = purchase(id: "second-purchase", rate: 37.5, count: 4, hoursAgo: 8, totalMinor: 1600)
        XCTAssertTrue(store.saveSupply(first))
        XCTAssertTrue(store.saveSupply(second))
        let beforeCorrection = try XCTUnwrap(InventorySnapshot(store: store).ledger.uses.first)
        XCTAssertTrue(beforeCorrection.missingStock)
        XCTAssertTrue(beforeCorrection.parts.isEmpty)

        let laterDose = DoseEvent(id: "later-dose", route: .patchApply, timeH: now - 3, doseMG: 0, ester: "E2",
                                  extras: ["patchCount": 3, "releaseRateUGPerDay": 112.5], inventorySupplyId: second.id)
        XCTAssertTrue(store.saveDose(laterDose))
        first.startedAt = milliseconds(hoursAgo: 24)
        XCTAssertTrue(store.saveSupply(first))

        let reopened = TrackerStore(context: ModelContext(container))
        let ledger = InventorySnapshot(store: reopened).ledger
        let previous = try XCTUnwrap(ledger.uses.first { $0.id == earlierDose.id })
        let recent = try XCTUnwrap(ledger.uses.first { $0.id == laterDose.id })
        XCTAssertTrue(previous.complete)
        XCTAssertEqual(previous.parts.map(\.supply.id), [first.id])
        XCTAssertEqual(previous.parts.map(\.cost), [3])
        XCTAssertEqual(recent.dose.inventorySupplyId, second.id)
        XCTAssertEqual(recent.parts.map(\.supply.id), [first.id, second.id])
        XCTAssertEqual(recent.parts.map(\.units), [1, 2])
        XCTAssertEqual(recent.parts.map(\.cost), [3, 8])
        XCTAssertEqual(reopened.supplies.first { $0.id == first.id }, first)
        XCTAssertEqual(ledger.remaining, [first.id: 1, second.id: 2, wrongStrength.id: 6])

        XCTAssertTrue(reopened.deleteSupply(wrongStrength.id))
        let archived = try XCTUnwrap(reopened.supplies.first { $0.id == wrongStrength.id })
        XCTAssertNotNil(archived.archivedAt)
        XCTAssertEqual(archived.purchase, wrongStrength.purchase)
        XCTAssertFalse(InventorySnapshot(store: reopened).statuses.contains { $0.id == archived.id })
    }

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

    func testUnitPriceDisplaysTwoDecimalsAndKeepsThePurchaseTotal() throws {
        let previous = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.preferenceKey) }
        let purchase = StockPurchase(unitsPerPack: 8, packCount: 1, totalMinor: 1001, currency: .CNY)
        let unitPrice = try XCTUnwrap(purchase.unitPrice)
        for (language, price, total) in [("en", "1.25", "10.01"), ("de", "1,25", "10,01")] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            let displayed = stockMoney(unitPrice, .CNY, unit: true).filter { $0.isNumber || ".,".contains($0) }
            XCTAssertEqual(displayed, price)
            XCTAssertTrue(stockMoney(unitPrice * 8, .CNY).contains(total))
        }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        XCTAssertTrue(stockMoney(2, .JPY, unit: true).contains("2.00"))
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
            XCTAssertEqual(records.plans.first?.value.inventorySupplyId, "older")
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
