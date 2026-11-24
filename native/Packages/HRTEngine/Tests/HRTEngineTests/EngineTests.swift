import Foundation
import Testing
@testable import HRTEngine

struct EngineTests {
    @Test func exponentialDifferencesHandleCoincidentRates() {
        let elapsed = 14.0
        let rate = 0.041
        let first = KineticMath.firstDifference(rate, rate + 1e-12, elapsed)
        let second = KineticMath.secondDifference(rate + 1e-12, rate - 1e-12, rate, elapsed)
        #expect(abs(first - (-elapsed * exp(-rate * elapsed))) < 1e-9)
        #expect(abs(second - (elapsed * elapsed * exp(-rate * elapsed) / 2)) < 1e-9)
    }

    @Test func sublingualRoundTripAndOverrideLimits() {
        for hold in [1.0, 2, 5, 10, 15, 30, 60] {
            let theta = HRTEngine.sublingualTheta(fromHoldMinutes: hold)
            #expect(HRTEngine.sublingualHoldMinutes(fromTheta: theta) == hold)
        }
        let parameters = PKParameters(overrides: ["e2_kClear": -1, "e2_kClearInj": 12])
        #expect(parameters.e2Clearance == 0.001)
        #expect(parameters.e2InjectionClearance == 1)
    }

    @Test func oneRemovalPairsWithOnePatchEvenForDuplicateIDs() throws {
        let time = 498_192.0
        let patch = DoseEvent(
            id: "duplicate", route: .patchApply, timeH: time, doseMG: 0, ester: "E2",
            extras: ["releaseRateUGPerDay": 50]
        )
        let removal = DoseEvent(route: .patchRemove, timeH: time + 48, doseMG: 0, ester: "E2")
        let at = time + 72
        let paired = try #require(HRTEngine.exactConcentration(events: [patch, patch, removal], weight: 70, at: at))
        let worn = try #require(HRTEngine.exactConcentration(events: [patch], weight: 70, at: at))
        let removed = try #require(HRTEngine.exactConcentration(events: [patch, removal], weight: 70, at: at))
        #expect(abs(paired.e2 - (worn.e2 + removed.e2)) < 1e-9)
    }

    @Test func projectedPatchDoesNotClaimRecordedRemoval() throws {
        let time = 498_192.0
        let now = time + 79
        let patch = DoseEvent(
            id: "recorded", route: .patchApply, timeH: time, doseMG: 0, ester: "E2",
            extras: ["releaseRateUGPerDay": 100, "patchWearH": 48]
        )
        let removal = DoseEvent(route: .patchRemove, timeH: time + 84, doseMG: 0, ester: "E2")
        let replacement = DoseEvent(
            id: "projected", route: .patchApply, timeH: time + 80, doseMG: 0, ester: "E2",
            extras: patch.extras
        )
        let recorded = [patch, removal]
        let baseline = try #require(HRTEngine.simulate(events: recorded, weight: 70, nowH: now))
        let projection = try #require(HRTEngine.simulate(
            events: recorded, weight: 70, nowH: now, projectedEvents: [replacement]
        ))
        let combined = try #require(HRTEngine.simulate(events: recorded + [replacement], weight: 70, nowH: now))
        #expect(baseline.value(at: now)?.e2 == projection.value(at: now)?.e2)
        #expect((combined.value(at: now)?.e2 ?? .infinity) < 1)
        #expect((projection.value(at: time + 108)?.e2 ?? 0) > 70)

        let exact = try #require(HRTEngine.exactConcentration(
            events: recorded, weight: 70, at: now, projectedEvents: [replacement]
        ))
        #expect(exact.e2 == baseline.value(at: now)?.e2)

        // The clearance grid must use the same provenance as the simulated baseline.
        let labs = [24, 48, 72].map { offset in
            LabResult(timeH: time + Double(offset), concValue: 100, unit: "pg/ml")
        }
        var resolvedPatch = patch
        resolvedPatch.extras["patchWearH"] = 84
        let explicitWear = try #require(HRTEngine.simulate(
            events: [resolvedPatch], weight: 70, nowH: now, throughH: time + 500, projectedEvents: [replacement]
        ))
        let projectedToHorizon = try #require(HRTEngine.simulate(
            events: recorded, weight: 70, nowH: now, throughH: time + 500, projectedEvents: [replacement]
        ))
        let fit = HRTEngine.calibrate(
            simulation: projectedToHorizon, events: recorded, weight: 70, labs: labs,
            method: .mipd, history: .retrospective, projectedEvents: [replacement]
        )
        let explicitWearFit = HRTEngine.calibrate(
            simulation: explicitWear, events: [resolvedPatch], weight: 70, labs: labs,
            method: .mipd, history: .retrospective, projectedEvents: [replacement]
        )
        #expect(fit.count == 3)
        #expect(abs(fit.kMul - 1) > 0.01)
        #expect(abs(fit.factor(at: time + 108) - explicitWearFit.factor(at: time + 108)) < 1e-9)
    }

    @Test func projectedRemovalCanEndOnlyAnUnpairedPatch() throws {
        let time = 498_192.0
        let patch = DoseEvent(
            route: .patchApply, timeH: time, doseMG: 0, ester: "E2",
            extras: ["releaseRateUGPerDay": 100, "patchWearH": 84]
        )
        let removal = DoseEvent(route: .patchRemove, timeH: time + 72, doseMG: 0, ester: "E2")
        let projectedRemoval = DoseEvent(route: .patchRemove, timeH: time + 48, doseMG: 0, ester: "E2")
        let at = time + 60
        let takenOff = try #require(HRTEngine.exactConcentration(
            events: [patch], weight: 70, at: at, projectedEvents: [projectedRemoval]
        ))
        let recordedRemovalTakesPrecedence = try #require(HRTEngine.exactConcentration(
            events: [patch, removal], weight: 70, at: at, projectedEvents: [projectedRemoval]
        ))
        #expect(takenOff.e2 < 1)
        #expect(recordedRemovalTakesPrecedence.e2 > 70)
    }

    @Test func concentrationSupportMatchesRouteModels() {
        let time = 498_192.0
        #expect(!HRTEngine.supportsConcentration(DoseEvent(route: .patchRemove, timeH: time, doseMG: 0, ester: "E2")))
        #expect(!HRTEngine.supportsConcentration(DoseEvent(route: .sc, timeH: time, doseMG: 10, ester: "T")))
        #expect(HRTEngine.supportsConcentration(DoseEvent(route: .sc, timeH: time, doseMG: 10, ester: "TC")))
        #expect(!HRTEngine.supportsConcentration(DoseEvent(route: .oral, timeH: time, doseMG: 1, ester: "UNKNOWN")))
        #expect(!HRTEngine.supportsConcentration(DoseEvent(route: .oral, timeH: time, doseMG: 0, ester: "CPA")))
        #expect(HRTEngine.supportsConcentration(DoseEvent(
            route: .patchApply, timeH: time, doseMG: 0, ester: "E2", extras: ["releaseRateUGPerDay": 100]
        )))
    }

    @Test func patchReferenceConcentrationAndForecastWindow() throws {
        let t0 = 498_192.0
        let now = 499_000.0
        let event = DoseEvent(
            route: .patchApply, timeH: t0, doseMG: 0, ester: "E2",
            extras: ["releaseRateUGPerDay": 100, "patchWearH": 48]
        )
        let simulation = try #require(HRTEngine.simulate(events: [event], weight: 70, nowH: now, throughH: now + 600))
        let wearing = try #require(HRTEngine.exactConcentration(events: [event], weight: 70, at: t0 + 24))
        let after = try #require(simulation.value(at: now))
        #expect(abs(wearing.e2 - 72.5866) < 0.001)
        #expect(after.e2 == 0)
        #expect(simulation.points.last?.timeH == now + 600)
    }
}
