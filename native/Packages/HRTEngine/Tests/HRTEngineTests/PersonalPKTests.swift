import Testing
@testable import HRTEngine

struct PersonalPKTests {
    @Test func matchesWebPosteriorAndHistory() throws {
        let nowH = 480_000.0
        let injections = [500.0, 332, 164].enumerated().map { index, offset in
            DoseEvent(id: "inj\(index)", route: .injection, timeH: nowH - offset, doseMG: 3.5, ester: "EV")
        }
        let sublingual = (0..<18).map { index in
            DoseEvent(
                id: "sl\(index)", route: .sublingual, timeH: nowH - Double((17 - index) * 12 + 5),
                doseMG: 1.5, ester: "E2", extras: ["sublingualTier": 2]
            )
        }
        let events = injections + sublingual
        let labOffsets = [450.0, 290, 168, 158, 98, 30]
        let observed = [
            265.1346279450106, 297.8127643208055, 132.52215732898622,
            191.36314818108877, 386.45220092882266, 177.58399767766744
        ]
        let labs = zip(labOffsets, observed).enumerated().map { index, sample in
            LabResult(
                id: "lab\(index)", timeH: nowH - sample.0, concValue: sample.1,
                unit: "pg/ml", assay: index.isMultiple(of: 2) ? "immuno" : "lcms"
            )
        }
        let simulation = try #require(HRTEngine.simulate(events: events, weight: 70, nowH: nowH))
        let sampleOffsets = [-460.0, -289, -157, -30, 6]
        // Reference values from calibrateSimulation in src/domain/calibration/index.ts
        // with Date.now fixed at nowH and the same synthetic events and labs.
        let reference: [(CalibrationHistoryMode, Double, [Double], [Double])] = [
            (
                .retrospective, 4.713641680173741,
                [1.1456267053524, 1.1283026259095925, 1.0246035621103418, 1.0297250721263547, 1.0142575029987089],
                [0.11436451371625518, 0.10390333575878151, 0.10605093739645854, 0.08434499583938393, 0.10730856885167712]
            ),
            (
                .forward, 5.049565517670351,
                [1, 1.1318767150366462, 1.0173782682368506, 1.0203427782608423, 1.0059409566980195],
                [0, 0.09571431499978997, 0.14762837340967525, 0.10131411985466462, 0.12515264562738312]
            )
        ]
        for (history, error, factors, deviations) in reference {
            let fit = HRTEngine.calibrate(
                simulation: simulation, events: events, weight: 70, labs: labs, method: .mcmc, history: history
            )
            #expect(fit.method == .mcmc)
            #expect(fit.count == labs.count)
            #expect(fit.discounted == 0)
            #expect(near(fit.scale, 1.1206586791662378))
            #expect(near(fit.kMul, 1.058242941334706))
            #expect(near(try #require(fit.absMul), 1.0516193068761734))
            #expect(near(try #require(fit.rHat), 1.0071958913152166))
            #expect(near(try #require(fit.fitErrPct), error))
            let routes = try #require(fit.routeScales)
            #expect(routes.count == 2)
            #expect(near(try #require(routes[.sublingual]), 0.9799175685523341))
            #expect(near(try #require(routes[.injection]), 1.1538428336501227))
            let interval = try #require(fit.latestInterval)
            #expect(near(interval.lowerBound, 0.8802044995268503))
            #expect(near(interval.upperBound, 1.184150083672557))
            for (offset, expected) in zip(sampleOffsets, zip(factors, deviations)) {
                let timeH = nowH + offset
                #expect(near(fit.factor(at: timeH), expected.0), "\(history) factor at \(offset) h")
                #expect(near(try #require(fit.factorSD(at: timeH)), expected.1), "\(history) log SD at \(offset) h")
            }
        }
    }

    @Test func personalizationKeepsPatchPairingAndZeroOrderRelease() throws {
        let start = 480_000.0
        let patch = DoseEvent(
            route: .patchApply, timeH: start, doseMG: 0, ester: "E2",
            extras: ["releaseRateUGPerDay": 100, "patchWearH": 48]
        )
        let removal = DoseEvent(route: .patchRemove, timeH: start + 84, doseMG: 0, ester: "E2")
        var replacement = patch
        replacement.id = "projected"
        replacement.timeH = start + 80
        let events = [patch, removal, DoseEvent(route: .oral, timeH: start + 48, doseMG: 6, ester: "CPA")]
        let projected = [replacement]
        let routes = HRTEngine.estradiolRoutes(events: events, projectedEvents: projected)
        #expect(routes == [.patchApply])
        let times = [start + 72, start + 108]
        let curves = HRTEngine.estradiolRouteCurves(
            events: events, projectedEvents: projected, weight: 70, birthYear: nil, times: times,
            routes: routes, parameters: PKParameters(), clearanceMultiplier: 1, absorptionMultiplier: 2
        )
        let estrogen = try #require(curves.first)
        for (time, level) in zip(times, estrogen) {
            let baseline = try #require(HRTEngine.exactConcentration(
                events: events, weight: 70, at: time, projectedEvents: projected
            ))
            #expect(baseline.e2 > 70)
            #expect(abs(level - baseline.e2) < 1e-9)
        }
    }

    private func near(_ actual: Double, _ expected: Double) -> Bool {
        abs(actual - expected) <= 2e-7 + 2e-5 * abs(expected)
    }
}
