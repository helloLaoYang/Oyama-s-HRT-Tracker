import Foundation
import HRTEngine
import SwiftData
import UIKit
import XCTest
@testable import HRTTracker

final class OverviewRefreshTests: XCTestCase {
    @MainActor
    func testRefreshIndicatorStaysHiddenWhenRefreshInsetIsRemoved() throws {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        scroll.contentSize = CGSize(width: 320, height: 1_000)
        let control = UIRefreshControl()
        scroll.refreshControl = control
        let originalSubviews = control.subviews
        let coordinator = OverviewRefreshControl.Coordinator()
        coordinator.attach(to: scroll)
        defer { coordinator.detach() }
        let indicator = try XCTUnwrap(control.subviews.first { view in
            !originalSubviews.contains { $0 === view }
        })

        coordinator.setPhase(.refreshing)
        coordinator.setPhase(.finishing)
        scroll.contentInset.top = 60
        scroll.contentOffset.y = -60
        coordinator.setPhase(.pulling)

        scroll.contentInset.top = 0
        scroll.contentOffset.y = -60

        XCTAssertEqual(indicator.alpha, 0)
        XCTAssertTrue(indicator.isHidden)
    }

    @MainActor
    func testRefreshRereadsSavedDosesAndUpdatesClock() throws {
        let config = ModelConfiguration(schema: TrackerStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TrackerStore.schema, configurations: [config])
        let store = TrackerStore(context: container.mainContext)
        let writer = TrackerStore(context: ModelContext(container))
        let dose = DoseEvent(id: "saved-dose", route: .oral, timeH: store.nowH - 1, doseMG: 1, ester: "E2")
        XCTAssertTrue(writer.saveDose(dose))
        XCTAssertTrue(store.doses.isEmpty)

        let beforeRefresh = Date()
        try store.refreshOverviewData()

        XCTAssertEqual(store.doses.map(\.id), [dose.id])
        XCTAssertGreaterThanOrEqual(store.now, beforeRefresh)
    }
}
