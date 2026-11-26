import Foundation
import Testing
@testable import HRTEngine

struct GoldenTests {
    @Test func simulationMatchesTypeScript() throws {
        let reference = try GoldenFile.load()
        #expect(reference.fixtures.count == 19)

        for fixture in reference.fixtures {
            let parameters = PKParameters(overrides: fixture.pk ?? [:])
            let simulation = try #require(HRTEngine.simulate(
                events: fixture.events, weight: fixture.weight, nowH: reference.nowH,
                birthYear: fixture.birthYear, parameters: parameters
            ))
            #expect(simulation.points.count == fixture.gridLen, "\(fixture.name): grid")
            #expect(close(simulation.auc, fixture.auc, absolute: 0, relative: 1e-7), "\(fixture.name): AUC")
            for expected in fixture.samples {
                let time = reference.T0H + expected.offsetH
                let sample = try #require(simulation.value(at: time))
                let analytic = try #require(HRTEngine.exactConcentration(
                    events: fixture.events, weight: fixture.weight, at: time,
                    birthYear: fixture.birthYear, parameters: parameters
                ))
                let name = "\(fixture.name) at \(expected.offsetH) h"
                #expect(close(analytic.e2, expected.exactE2, absolute: 1e-6, relative: 1e-9), "\(name): analytic E2")
                #expect(close(analytic.cpa, expected.exactCPA, absolute: 1e-6, relative: 1e-9), "\(name): analytic CPA")
                #expect(close(sample.e2, expected.simE2, absolute: 1e-6, relative: 1e-7), "\(name): E2")
                #expect(close(sample.cpa, expected.simCPA, absolute: 1e-6, relative: 1e-7), "\(name): CPA")
                #expect(close(sample.testosterone, expected.simT, absolute: 1e-6, relative: 1e-7), "\(name): total T")
            }
        }
    }

    @Test func calibrationMatchesTypeScript() throws {
        let reference = try GoldenFile.load()
        #expect(reference.calibration.count == 5)

        for fixture in reference.calibration {
            let base = try #require(reference.fixtures.first { $0.name == fixture.baseFixture })
            let simulation = try #require(HRTEngine.simulate(events: base.events, weight: base.weight, nowH: reference.nowH))
            let fit = HRTEngine.calibrate(
                simulation: simulation, events: base.events, weight: base.weight,
                labs: fixture.labs, method: fixture.method, history: fixture.historyMode
            )
            #expect(close(fit.scale, fixture.scale, absolute: 1e-9, relative: 1e-4), "\(fixture.name): amplitude")
            #expect(close(fit.kMul, fixture.kMul, absolute: 1e-9, relative: 1e-4), "\(fixture.name): clearance")
            #expect(close(fit.halfLifeDeltaPct, fixture.halfLifeDeltaPct, absolute: 0.01, relative: 1e-4), "\(fixture.name): half-life")
            if let expected = fixture.fitErrPct {
                let measured = try #require(fit.fitErrPct)
                #expect(abs(measured - expected) <= 0.01, "\(fixture.name): fit error")
            } else {
                #expect(fit.fitErrPct == nil, "\(fixture.name): fit error")
            }
            #expect(fit.count == fixture.labs.count)
            for expected in fixture.at {
                let time = reference.T0H + expected.offsetH
                let sample = try #require(simulation.value(at: time))
                let factor = fit.factor(at: time)
                let name = "\(fixture.name) at \(expected.offsetH) h"
                #expect(close(factor, expected.factor, absolute: 1e-9, relative: 1e-4), "\(name): factor")
                #expect(close(sample.e2 * factor, expected.calibratedE2, absolute: 1e-9, relative: 1e-4), "\(name): calibrated E2")
            }
        }
    }

    private func close(_ value: Double, _ expected: Double, absolute: Double, relative: Double) -> Bool {
        abs(value - expected) <= absolute + relative * abs(expected)
    }
}

private struct GoldenFile: Decodable {
    struct Fixture: Decodable {
        struct Sample: Decodable {
            var offsetH: Double
            var exactE2: Double
            var exactCPA: Double
            var simE2: Double
            var simCPA: Double
            var simT: Double
        }
        var name: String
        var weight: Double
        var birthYear: Int?
        var pk: [String: Double]?
        var events: [DoseEvent]
        var gridLen: Int
        var auc: Double
        var samples: [Sample]
    }

    struct CalibrationCase: Decodable {
        struct Sample: Decodable {
            var offsetH: Double
            var factor: Double
            var calibratedE2: Double
        }
        var name: String
        var baseFixture: String
        var method: CalibrationMethod
        var historyMode: CalibrationHistoryMode
        var labs: [LabResult]
        var scale: Double
        var kMul: Double
        var halfLifeDeltaPct: Double
        var fitErrPct: Double?
        var at: [Sample]
    }

    var fixedNowMs: Double
    var T0H: Double
    var fixtures: [Fixture]
    var calibration: [CalibrationCase]
    var nowH: Double { fixedNowMs / 3_600_000 }

    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(forResource: "golden", withExtension: "json"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
