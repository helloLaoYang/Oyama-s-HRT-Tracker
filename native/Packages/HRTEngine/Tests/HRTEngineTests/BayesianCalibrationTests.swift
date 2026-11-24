import Foundation
import Testing
@testable import HRTEngine

struct BayesianCalibrationTests {
    @Test func reproducesWebPosteriorAndUncertainty() throws {
        let fixtures = try References.load()
        let simulation = try #require(HRTEngine.simulate(events: fixtures.events, weight: 70, nowH: fixtures.nowH))
        #expect(fixtures.cases.count == 5)
        for fixture in fixtures.cases {
            let fit = HRTEngine.calibrate(
                simulation: simulation, events: fixtures.events, weight: 70, labs: fixture.labs,
                method: .bayes, history: fixture.history
            )
            #expect(fit.method == .bayes)
            #expect(fit.count == fixture.labs.count)
            #expect(near(fit.scale, fixture.scale), "\(fixture.name) amplitude")
            #expect(near(fit.kMul, fixture.kMul), "\(fixture.name) clearance")
            #expect(fit.discounted == fixture.discounted, "\(fixture.name) discounted")
            if let expected = fixture.fitErrPct {
                let actual = try #require(fit.fitErrPct)
                #expect(near(actual, expected), "\(fixture.name) fit error")
            } else {
                #expect(fit.fitErrPct == nil)
            }
            let interval = try #require(fit.latestInterval)
            #expect(near(interval.lowerBound, fixture.interval[0]), "\(fixture.name) credible lower")
            #expect(near(interval.upperBound, fixture.interval[1]), "\(fixture.name) credible upper")
            let drift = try #require(fit.drift)
            #expect(Set(drift.keys) == Set(fixture.drift.keys))
            #expect(abs(drift.values.reduce(0, +) - 1) < 1e-9)
            for (family, expected) in fixture.drift {
                let probability = try #require(drift[family])
                #expect(near(probability, expected), "\(fixture.name) drift probability: \(family)")
            }
            for sample in fixture.samples {
                let factor = fit.factor(at: sample.timeH)
                let uncertainty = try #require(fit.factorSD(at: sample.timeH))
                #expect(near(factor, sample.factor), "\(fixture.name) factor at \(sample.timeH)")
                #expect(near(uncertainty, sample.sd), "\(fixture.name) log SD at \(sample.timeH)")
            }
            if fixture.history == .forward {
                let beforeFirst = try #require(fixture.labs.first).timeH - 1
                #expect(fit.factor(at: beforeFirst) == 1)
                #expect(fit.factorSD(at: beforeFirst) == 0)
            }
        }
    }

    private func near(_ actual: Double, _ expected: Double) -> Bool {
        abs(actual - expected) <= 2e-7 + 2e-5 * abs(expected)
    }
}

private struct References: Decodable {
    struct Case: Decodable {
        struct Sample: Decodable {
            let timeH: Double
            let factor: Double
            let sd: Double
        }
        let name: String
        let history: CalibrationHistoryMode
        let labs: [LabResult]
        let scale: Double
        let kMul: Double
        let fitErrPct: Double?
        let interval: [Double]
        let discounted: Int
        let drift: [String: Double]
        let samples: [Sample]
    }

    let nowH: Double
    let events: [DoseEvent]
    let cases: [Case]

    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(forResource: "bayes-golden", withExtension: "json"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
