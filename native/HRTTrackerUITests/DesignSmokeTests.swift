import XCTest

final class DesignSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOverviewLayoutAndSimulationNavigation() {
        let app = launchDemo()
        let overview = app.scrollViews.firstMatch
        let e2 = element("timeline.plot.e2", in: app)
        let cpa = element("timeline.plot.cpa", in: app)
        let heatmap = app.staticTexts["用药统计"]

        XCTAssertTrue(app.staticTexts["今日方案"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["更换雌二醇贴片"].exists)
        XCTAssertTrue(app.staticTexts["醋酸环丙孕酮"].exists)
        let chartTitle = app.staticTexts["激素浓度变化曲线"]
        let rangeButtons = ["7天", "30天", "全部"].map { app.buttons[$0] }
        XCTAssertTrue(chartTitle.waitForExistence(timeout: 8))
        var previousRightEdge = chartTitle.frame.maxX
        for button in rangeButtons {
            XCTAssertTrue(button.exists)
            XCTAssertEqual(chartTitle.frame.midY, button.frame.midY, accuracy: 2)
            XCTAssertLessThanOrEqual(previousRightEdge, button.frame.minX)
            previousRightEdge = button.frame.maxX
        }
        screenshot("01-overview-light", in: app)

        // Start above the chart so the swipe is handled by the page.
        let from = overview.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.54))
        let to = overview.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.24))
        from.press(forDuration: 0.05, thenDragTo: to)
        screenshot("02-aligned-concentration-curves", in: app)
        XCTAssertTrue(cpa.isHittable)
        XCTAssertTrue(e2.exists)
        XCTAssertTrue(cpa.exists)
        XCTAssertEqual(e2.frame.minX, cpa.frame.minX, accuracy: 1)
        XCTAssertEqual(e2.frame.width, cpa.frame.width, accuracy: 1)
        XCTAssertGreaterThan(e2.frame.width, overview.frame.width * 0.8)
        XCTAssertLessThanOrEqual(e2.frame.maxY, cpa.frame.minY)
        XCTAssertTrue(element("timeline.readout", in: app).exists)

        scroll(overview, until: heatmap)
        XCTAssertTrue(heatmap.isHittable)
        let selectedDay = element("heatmap.selected", in: app)
        scroll(overview, until: selectedDay)
        XCTAssertTrue(selectedDay.label.contains("0 次用药"))
        scroll(overview, until: app.buttons["overview.forecast"])
        screenshot("03-medication-activity", in: app)
        app.buttons["overview.forecast"].tap()

        let simulation = app.navigationBars["方案试算"]
        XCTAssertTrue(simulation.waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["forecast.edit"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["8 周"].exists)
        XCTAssertTrue(element("forecast.chart", in: app).waitForExistence(timeout: 100))
        screenshot("04-regimen-simulation", in: app)
        app.buttons["forecast.add"].tap()
        XCTAssertTrue(app.buttons["方案 B"].exists)
        app.buttons["forecast.edit"].tap()
        XCTAssertTrue(app.navigationBars["编辑试算方案"].waitForExistence(timeout: 5))
    }

    func testDarkAppearanceAndNativeEntrySheets() {
        let app = launchDemo()
        app.tabBars.buttons["设置"].tap()
        app.buttons["settings.general"].tap()
        app.buttons["settings.appearance"].tap()
        app.buttons["appearance.dark"].tap()
        XCTAssertTrue(app.navigationBars["外观设置"].exists)
        screenshot("05-appearance-dark", in: app)

        app.tabBars.buttons["概览"].tap()
        XCTAssertTrue(app.buttons["overview.addDose"].waitForExistence(timeout: 6))
        screenshot("06-overview-dark", in: app)
        scroll(app.scrollViews.firstMatch, until: element("timeline.plot.cpa", in: app))
        screenshot("07-concentration-curves-dark", in: app)
        app.scrollViews.firstMatch.swipeDown()
        app.buttons["overview.addDose"].tap()
        XCTAssertTrue(app.buttons["dose.save"].waitForExistence(timeout: 6))
        screenshot("08-dose-entry-drawer", in: app)
        app.buttons["dose.cancel"].tap()

        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(app.buttons["history.addDose"].waitForExistence(timeout: 6))
        screenshot("09-records-dark", in: app)
        app.tabBars.buttons["检查"].tap()
        XCTAssertTrue(app.buttons["labs.addLab"].waitForExistence(timeout: 6))
        screenshot("10-checks-dark", in: app)
        app.buttons["labs.addLab"].tap()
        XCTAssertTrue(app.buttons["lab.save"].waitForExistence(timeout: 6))
        screenshot("11-lab-entry-drawer", in: app)
        let concentration = app.textFields["lab.value"]
        concentration.tap()
        concentration.typeText("87")
        app.buttons["lab.save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "87")).firstMatch
            .waitForExistence(timeout: 8))
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func scroll(_ view: XCUIElement, until target: XCUIElement) {
        for _ in 0..<4 where !target.isHittable {
            let from = view.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.79))
            let to = view.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.4))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        XCTAssertTrue(target.isHittable)
    }

    private func screenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
