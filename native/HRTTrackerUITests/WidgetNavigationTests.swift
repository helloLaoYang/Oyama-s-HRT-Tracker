import XCTest

final class WidgetNavigationTests: XCTestCase {
    func testWidgetURLsOpenTheSelectedOverviewDestination() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        app.tabBars.buttons["记录"].tap()
        app.open(URL(string: "hrttracker://concentration/estimate/cpa")!)
        XCTAssertTrue(app.staticTexts["widget.detail.estimate"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["widget.detail.metric.cpa"].exists)

        app.open(URL(string: "hrttracker://concentration/trend/e2")!)
        XCTAssertTrue(app.staticTexts["widget.detail.trend"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["widget.detail.metric.e2"].exists)
        XCTAssertFalse(app.staticTexts["widget.detail.estimate"].exists)

        app.open(URL(string: "hrttracker://concentration")!)
        XCTAssertTrue(app.buttons["overview.estimate.info"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["widget.detail.trend"].exists)
    }
}
