import XCTest

final class DesignSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMedicationCostFromStockPurchase() throws {
        let app = launchDemo()
        let overview = app.scrollViews.firstMatch
        let add = app.buttons["cost.stock.oral|CPA"]
        waitUntilEnabled(app.buttons["overview.share"])
        overview.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.54))
            .press(forDuration: 0.05, thenDragTo: overview.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.24)))
        scroll(overview, until: add)
        add.tap()
        XCTAssertTrue(app.navigationBars["添加药品"].waitForExistence(timeout: 6))
        let strength = app.textFields["inventory.strength"]
        strength.tap()
        strength.press(forDuration: 1.1)
        let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["全选", "Select All"])).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3), app.debugDescription)
        selectAll.tap()
        strength.typeText("12.5")
        XCTAssertEqual(strength.value as? String, "12.5")
        app.buttons["完成"].firstMatch.tap()
        let count = app.textFields["inventory.count"]
        count.tap()
        count.typeText("28")
        app.buttons["完成"].firstMatch.tap()
        let cost = app.textFields["inventory.totalPrice"]
        let form = app.collectionViews.firstMatch
        if !cost.isHittable { form.swipeUp() }
        cost.tap()
        cost.typeText("56")
        app.buttons["完成"].firstMatch.tap()
        screenshot("cost-purchase", in: app)
        app.buttons["inventory.save"].tap()
        let total = app.staticTexts["cost.total.CNY"]
        scroll(overview, until: total)
        XCTAssertTrue(total.label.contains("3.00"), total.label)
        app.buttons["cost.range.today"].tap()
        XCTAssertTrue(app.staticTexts["所选时段暂无用药记录"].exists)
        app.buttons["cost.range.last7"].tap()
        XCTAssertTrue(total.label.contains("3.00"))
        app.buttons["cost.range.all"].tap()
        XCTAssertTrue(total.label.contains("3.00"))
        app.buttons["cost.range.last30"].tap()
        scroll(overview, until: app.buttons["cost.inventory"])
        screenshot("cost-overview", in: app)
        app.buttons["cost.details"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "1.5")).firstMatch.exists)

        let inventoryLink = app.buttons["cost.inventory"]
        scroll(overview, until: inventoryLink)
        inventoryLink.tap()
        app.buttons["inventory.add"].tap()
        app.buttons["inventory.medication"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "醋酸环丙孕酮")).firstMatch.tap()
        let secondCount = app.textFields["inventory.count"]
        secondCount.tap()
        secondCount.typeText("8")
        app.buttons["完成"].firstMatch.tap()
        app.buttons["inventory.save"].tap()
        let inventory = app.navigationBars["药量库存"]
        XCTAssertTrue(inventory.waitForExistence(timeout: 6))
        inventory.buttons.firstMatch.tap()

        let planLink = app.buttons["overview.plan"]
        for _ in 0..<5 where !planLink.isHittable { overview.swipeDown() }
        planLink.tap()
        app.buttons["plan.edit.CPA"].tap()
        let spec = app.buttons["plan.inventorySpec"]
        XCTAssertTrue(spec.waitForExistence(timeout: 6))
        spec.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "12.5 mg/片")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "0.5 片")).firstMatch.exists)
        screenshot("plan-stock-preview", in: app)
        app.buttons["plan.save"].tap()
        app.navigationBars["用药方案"].buttons.firstMatch.tap()
        let taken = app.buttons["plan.complete.CPA"]
        XCTAssertTrue(taken.waitForExistence(timeout: 6))
        taken.tap()
        let today = app.buttons["cost.range.today"]
        scroll(overview, until: today)
        today.tap()
        XCTAssertTrue(total.label.contains("1.00"), total.label)
        scroll(overview, until: inventoryLink)
        inventoryLink.tap()
        let lot = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "inventory.supply.", "12.5 mg/片")).firstMatch
        XCTAssertTrue(lot.waitForExistence(timeout: 6))
        XCTAssertTrue(lot.label.contains("26 片"), lot.label)
        inventory.buttons.firstMatch.tap()
        let undo = app.buttons["撤销"]
        for _ in 0..<5 where !undo.isHittable { overview.swipeDown() }
        undo.tap()
        scroll(overview, until: today)
        XCTAssertTrue(app.staticTexts["所选时段暂无用药记录"].exists)
    }

    func testPatchStockUsesTheRecordedDailyRate() {
        let app = launchDemo()
        func restoreSystemLanguage() {
            app.tabBars.buttons["Settings"].tap()
            app.buttons["settings.general"].tap()
            app.buttons["settings.language"].tap()
            app.buttons["language.system"].tap()
        }
        if app.tabBars.buttons["Settings"].exists {
            restoreSystemLanguage()
            app.tabBars.buttons["概览"].tap()
        }
        let overview = app.scrollViews.firstMatch
        let add = app.buttons["cost.stock.patchApply|E2"]
        waitUntilEnabled(app.buttons["overview.share"])
        scroll(overview, until: add)
        add.tap()
        let rate = app.textFields["inventory.strength"]
        XCTAssertTrue(rate.waitForExistence(timeout: 6))
        XCTAssertEqual(rate.value as? String, "50")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "µg/天")).firstMatch.exists)
        let count = app.textFields["inventory.count"]
        count.tap()
        count.typeText("10")
        app.buttons["完成"].firstMatch.tap()
        let price = app.textFields["inventory.totalPrice"]
        if !price.isHittable { app.collectionViews.firstMatch.swipeUp() }
        price.tap()
        price.typeText("100")
        app.buttons["完成"].firstMatch.tap()
        app.buttons["inventory.save"].tap()
        let total = app.staticTexts["cost.total.CNY"]
        scroll(overview, until: total)
        XCTAssertTrue(total.label.contains("60.00"), total.label)
        app.buttons["cost.details"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "50 µg/天", "6")).firstMatch.exists)
        screenshot("patch-cost-daily-rate", in: app)
        app.tabBars.buttons["设置"].tap()
        app.buttons["settings.general"].tap()
        app.buttons["settings.language"].tap()
        app.buttons["language.en"].tap()
        addTeardownBlock { restoreSystemLanguage() }
        app.tabBars.buttons["Overview"].tap()
        scroll(overview, until: total)
        XCTAssertTrue(total.label.contains("60.00"), total.label)
        let english = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "50 µg/day", "6")).firstMatch
        if !english.exists { app.buttons["cost.details"].tap() }
        XCTAssertTrue(english.exists)
    }

    func testWebModelSettingsAndInventory() {
        let app = launchDemo()
        app.tabBars.buttons["设置"].tap()
        app.buttons["settings.about"].tap()
        app.buttons["settings.modelGuide"].tap()
        XCTAssertTrue(app.navigationBars["模型说明"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["一次用药"].exists)
        screenshot("15-model-guide", in: app)
        app.navigationBars["模型说明"].buttons.firstMatch.tap()
        app.navigationBars["关于"].buttons.firstMatch.tap()

        app.buttons["settings.general"].tap()
        app.buttons["settings.pkParameters"].tap()
        XCTAssertTrue(app.navigationBars["药物参数编辑"].waitForExistence(timeout: 8))
        let parameter = app.textFields["pk.value.e2_ff_EB"]
        let oldValue = parameter.value as? String ?? ""
        XCTAssertFalse(oldValue.isEmpty)
        parameter.tap()
        parameter.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count) + "0.2")
        app.buttons["pk.save"].tap()
        XCTAssertTrue(element("pk.customized", in: app).waitForExistence(timeout: 6))
        screenshot("16-drug-parameters", in: app)
        app.navigationBars["药物参数编辑"].buttons.firstMatch.tap()

        app.buttons["settings.inventory"].tap()
        XCTAssertTrue(app.navigationBars["药量库存"].waitForExistence(timeout: 8))
        app.buttons["inventory.add"].tap()
        let count = app.textFields["inventory.count"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 8))
        count.tap()
        count.typeText("1")
        app.buttons["inventory.save"].tap()
        let stock = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inventory.supply.")).firstMatch
        XCTAssertTrue(stock.waitForExistence(timeout: 8))
        screenshot("17-medication-inventory", in: app)
        app.tabBars.buttons["概览"].tap()
        let lowStock = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inventory.alert.")).firstMatch
        XCTAssertTrue(lowStock.waitForExistence(timeout: 8))

        app.tabBars.buttons["检查"].tap()
        app.buttons["labs.calibration"].tap()
        XCTAssertTrue(app.navigationBars["校准设置"].waitForExistence(timeout: 8))
        element("labs.calibration.method", in: app).tap()
        XCTAssertTrue(app.buttons["个人药代"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["全贝叶斯"].firstMatch.tap()
        let fit = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "全贝叶斯 · ×")).firstMatch
        XCTAssertTrue(fit.waitForExistence(timeout: 20))
        screenshot("18-advanced-calibration", in: app)
    }

    func testAppLanguagesAndOpenSourceLicenses() {
        let app = launchDemo()
        app.tabBars.buttons["设置"].tap()

        let settings = [("de", "Einstellungen"), ("fr", "Réglages"), ("ja", "設定"),
                        ("en", "Settings"), ("zh-Hans", "设置"), ("system", "设置")]
        for (language, title) in settings {
            app.buttons["settings.general"].tap()
            app.buttons["settings.language"].tap()
            let choice = app.buttons["language.\(language)"]
            XCTAssertTrue(choice.waitForExistence(timeout: 6))
            choice.tap()
            XCTAssertTrue(app.tabBars.buttons[title].waitForExistence(timeout: 6))

            if language == "fr" {
                app.terminate()
                app.launch()
                app.tabBars.buttons["Historique"].tap()
                XCTAssertEqual(app.buttons["history.select"].label, "Sélectionner")
                app.tabBars.buttons[title].tap()
            }
        }

        app.buttons["settings.about"].tap()
        XCTAssertTrue(element("settings.projectWebsite", in: app).exists)
        app.buttons["settings.licenses"].tap()
        XCTAssertTrue(app.navigationBars["开源许可"].waitForExistence(timeout: 6))
        XCTAssertTrue(element("licenses.pkSource", in: app).exists)
        let license = app.staticTexts["licenses.mit"]
        XCTAssertTrue(license.exists)
        XCTAssertTrue(license.label.contains("Copyright (c) 2025 Joseph Smirnova Oyama"))
        screenshot("23-open-source-licenses", in: app)
    }

    func testFeedbackFromAbout() {
        let app = launchDemo()
        app.tabBars.buttons["设置"].tap()
        app.buttons["settings.about"].tap()
        app.buttons["settings.feedback"].tap()

        XCTAssertTrue(app.navigationBars["意见反馈"].waitForExistence(timeout: 6))
        let submit = app.buttons["feedback.submit"]
        if app.staticTexts["feedback.unavailable"].exists {
            XCTAssertFalse(submit.exists)
            return
        }

        XCTAssertTrue(app.staticTexts["feedback.publicNotice"].exists)
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled)

        let title = app.textFields["feedback.title"]
        title.tap()
        title.typeText("Example title")
        XCTAssertFalse(submit.isEnabled)

        let body = element("feedback.body", in: app)
        body.tap()
        body.typeText("Example description")
        XCTAssertTrue(submit.isEnabled)
    }

    func testOverviewLayoutAndSimulationNavigation() {
        let app = launchDemo()
        let overview = app.scrollViews.firstMatch
        let e2 = element("timeline.plot.e2", in: app)
        let cpa = element("timeline.plot.cpa", in: app)
        let heatmap = app.staticTexts["用药统计"]

        let share = app.buttons["overview.share"]
        waitUntilEnabled(share)
        let estimate = app.buttons["overview.estimate.info"]
        XCTAssertEqual(estimate.label, "当前估算血药浓度")
        XCTAssertEqual(estimate.frame.midY, share.frame.midY, accuracy: 2)
        XCTAssertLessThan(estimate.frame.maxX, share.frame.minX)
        XCTAssertEqual(app.staticTexts["overview.estimate.status"].label, "相当于女性卵泡期")
        XCTAssertFalse(app.buttons["添加血检结果"].exists)
        XCTAssertTrue(app.staticTexts["今日方案"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["更换雌二醇贴片"].exists)
        XCTAssertTrue(app.staticTexts["醋酸环丙孕酮"].exists)
        let chartTitle = app.staticTexts["激素浓度变化曲线"]
        let chartRange = element("timeline.range", in: app)
        let rangeButtons = ["7天", "30天", "全部"].map { chartRange.buttons[$0] }
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

    func testOverviewSharePreviewAndSystemSheet() {
        let app = launchDemo()
        let share = app.buttons["overview.share"]
        waitUntilEnabled(share)
        share.tap()

        let title = app.navigationBars["分享预览"]
        let image = app.images["overview.share.image"]
        XCTAssertTrue(title.waitForExistence(timeout: 6))
        XCTAssertTrue(image.waitForExistence(timeout: 6))
        screenshot("19-share-preview", in: app)

        let caption = element("overview.share.caption", in: app)
        XCTAssertFalse((caption.value as? String ?? "").isEmpty)
        caption.tap()
        caption.typeText(" Share test")
        XCTAssertTrue((caption.value as? String ?? "").contains("Share test"))

        app.buttons["overview.share.send"].tap()
        let shareActions = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@ OR label IN %@",
            ["ActivityListView", "UIActivityContentView"],
            ["Copy", "拷贝", "复制", "Save to Files", "存储到“文件”"]
        ))
        XCTAssertTrue(shareActions.firstMatch.waitForExistence(timeout: 6), app.debugDescription)
        screenshot("20-system-share-sheet", in: app)
    }

    func testOverviewSingleReadingHeader() {
        let app = launchDemo()
        app.tabBars.buttons["记录"].tap()
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("CPA\n")

        let prefix = "history.record."
        let records = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        let identifiers = records.allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(identifiers.count, 3)
        for identifier in identifiers {
            let recordID = identifier.dropFirst(prefix.count)
            app.buttons["history.recordActions.\(recordID)"].tap()
            app.buttons["删除"].tap()
            XCTAssertTrue(app.staticTexts["删除所选用药记录？"].waitForExistence(timeout: 5))
            app.buttons["删除"].tap()
            XCTAssertTrue(app.buttons[identifier].waitForNonExistence(timeout: 5))
        }

        app.tabBars.buttons["概览"].tap()
        waitUntilEnabled(app.buttons["overview.share"])
        XCTAssertEqual(app.staticTexts["overview.estimate.status"].label, "相当于女性卵泡期")
        screenshot("22-overview-single-reading", in: app)
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
        let share = app.buttons["overview.share"]
        waitUntilEnabled(share)
        screenshot("06-overview-dark", in: app)
        share.tap()
        XCTAssertTrue(app.images["overview.share.image"].waitForExistence(timeout: 6))
        screenshot("21-share-preview-dark", in: app)
        app.buttons["overview.share.close"].tap()
        XCTAssertTrue(app.navigationBars["分享预览"].waitForNonExistence(timeout: 6))
        let overview = app.scrollViews.firstMatch
        let aboveChart = overview.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.54))
        let top = overview.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.24))
        aboveChart.press(forDuration: 0.05, thenDragTo: top)
        XCTAssertTrue(element("timeline.plot.cpa", in: app).isHittable)
        screenshot("07-concentration-curves-dark", in: app)

        app.tabBars.buttons["记录"].tap()
        let addDose = app.buttons["history.addDose"]
        XCTAssertTrue(addDose.waitForExistence(timeout: 6))
        screenshot("09-records-dark", in: app)
        addDose.tap()
        XCTAssertTrue(app.buttons["dose.save"].waitForExistence(timeout: 6))
        screenshot("08-dose-entry-drawer", in: app)
        app.buttons["dose.cancel"].tap()

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

    private func waitUntilEnabled(_ element: XCUIElement) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"),
                                                object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
    }

    private func scroll(_ view: XCUIElement, until target: XCUIElement) {
        for _ in 0..<6 where !target.isHittable {
            let chart = view.descendants(matching: .any).matching(identifier: "overview.timeline").firstMatch
            let frame = chart.exists ? chart.frame : .zero
            let height = view.frame.height
            // Begin outside the chart's drag-to-scrub area and above the floating tab bar.
            let y = frame.minY > height * 0.29 ? min(0.72, (frame.minY - 24) / height) : 0.72
            let x = frame.contains(CGPoint(x: view.frame.midX, y: height * y)) ? 0.985 : 0.52
            let from = view.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
            let to = view.coordinate(withNormalizedOffset: CGVector(dx: x, dy: max(0.12, y - 0.37)))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertTrue(target.isHittable, view.debugDescription)
    }

    private func screenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
