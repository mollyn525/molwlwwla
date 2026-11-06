import XCTest

final class WorkflowUITests: XCTestCase {
    func testSubjectCalibrationAndPinnedRecordingControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","--recording-dock-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["采集"].waitForExistence(timeout:15))
        app.tabBars.buttons["采集"].tap()
        let stop = app.buttons["recordingStop"]
        XCTAssertTrue(stop.waitForExistence(timeout:5)); XCTAssertTrue(stop.isHittable)
        let y = stop.frame.midY
        app.swipeUp()
        XCTAssertTrue(stop.isHittable); XCTAssertEqual(stop.frame.midY,y,accuracy:3)
        app.swipeDown()
        let preparation = app.buttons["受试者静态 / 动态校正"]
        XCTAssertTrue(preparation.exists); preparation.tap()
        XCTAssertTrue(app.navigationBars["受试者校正采集"].waitForExistence(timeout:5))
        XCTAssertTrue(stop.isHittable)
        app.swipeUp(); XCTAssertTrue(stop.isHittable)
        attach(app,"校正采集与固定结束按钮")
        app.terminate()
    }
    func testReadOnlyMonitorAndCalibrationPages() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launch()
        let monitor = app.buttons["liveMonitor"]
        XCTAssertTrue(monitor.waitForExistence(timeout:15)); monitor.tap()
        XCTAssertTrue(app.staticTexts["Magnetic Field (a.u.)"].waitForExistence(timeout:5))
        app.buttons["Orientation"].tap()
        let reset = app.buttons["Heading reset · 本台归零"]
        for _ in 0..<5 { if reset.exists { break }; app.swipeUp() }
        XCTAssertTrue(reset.exists); XCTAssertFalse(reset.isEnabled)
        app.tabBars.buttons["设置"].tap()
        app.buttons["singleMagCalibration"].tap()
        XCTAssertTrue(app.navigationBars["单台磁场校准"].waitForExistence(timeout:5))
        let start = app.buttons["开始单台磁场校准"], finish = app.buttons["结束并保存"]
        for _ in 0..<5 { if start.exists && finish.exists { break }; app.swipeUp() }
        XCTAssertTrue(start.exists); XCTAssertFalse(start.isEnabled)
        XCTAssertTrue(finish.exists); XCTAssertFalse(finish.isEnabled)
        attach(app,"单台磁场校准离线预览")
    }
    func testFiveTabsTaskPersistenceAndFormalGate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        addUIInterruptionMonitor(withDescription:"System Bluetooth prompt") { alert in
            for title in ["允许","Allow","好","OK"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["设备"].waitForExistence(timeout:15))
        app.tabBars.buttons["设备"].tap()
        for title in ["设备","采集","佩戴","记录","设置"] { XCTAssertTrue(app.tabBars.buttons[title].exists) }
        let head = app.buttons["bodyRole_head"], chest = app.buttons["bodyRole_thoracic_spine"]
        XCTAssertTrue(head.exists); XCTAssertTrue(chest.exists)
        XCTAssertEqual(head.frame.midX,chest.frame.midX,accuracy:2)
        XCTAssertGreaterThan(head.frame.midX,app.frame.width*0.4)
        XCTAssertLessThan(head.frame.midX,app.frame.width*0.6)
        XCTAssertLessThan(head.frame.midY,chest.frame.midY)
        XCTAssertGreaterThan(app.buttons["bodyRole_left_upper_arm"].frame.midX,app.buttons["bodyRole_right_upper_arm"].frame.midX)
        attach(app,"设备人体图")
        head.tap(); XCTAssertTrue(app.navigationBars["头部"].waitForExistence(timeout:5))
        app.tabBars.buttons["采集"].tap()
        app.buttons["新建受试者任务"].tap()
        let dialog = app.alerts["新建匿名受试者任务"]
        XCTAssertTrue(dialog.waitForExistence(timeout:5))
        dialog.textFields.firstMatch.tap(); dialog.textFields.firstMatch.typeText("S_UI_TEST")
        dialog.buttons["建立"].tap()
        app.buttons["开始正式收集"].tap()
        XCTAssertTrue(app.buttons["collectionAction0"].waitForExistence(timeout:5))
        attach(app,"八动作固定编号")
        app.buttons["collectionAction0"].tap()
        let start = app.buttons["formalStart"]
        XCTAssertTrue(start.waitForExistence(timeout:5)); XCTAssertFalse(start.isEnabled)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["formalBlockedReason"].waitForExistence(timeout:5))
        let help = app.buttons["formalBlockedHelp"]
        XCTAssertTrue(help.waitForExistence(timeout:5)); help.tap()
        XCTAssertTrue(app.navigationBars["采前检查清单"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["设备绑定与连接"].exists)
        XCTAssertTrue(app.buttons["佩戴确认与参考姿态"].exists)
        attach(app,"缺少设备时禁止正式录制")
        app.tabBars.buttons["佩戴"].tap()
        XCTAssertTrue(app.buttons["采集15部位完整参考姿态"].waitForExistence(timeout:5))
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(app.buttons["刷新记录"].waitForExistence(timeout:5))
        app.tabBars.buttons["设置"].tap()
        let applyConfiguration = app.buttons["应用 / 重试未达标设备"]
        // Settings is a scrollable list; on iPhone 16 this row starts below the viewport.
        for _ in 0..<4 { if applyConfiguration.exists { break }; app.swipeUp() }
        XCTAssertTrue(applyConfiguration.waitForExistence(timeout:5))
        XCTAssertFalse(applyConfiguration.isEnabled)
        attach(app,"配置与校准入口")
        let results = app.buttons["calibrationResults"]
        for _ in 0..<5 { if results.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(results.isHittable); results.tap()
        XCTAssertTrue(app.navigationBars["加速度校准结果"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["calibrationResultsEmpty"].exists)
        attach(app,"校准结果独立入口")
        app.terminate(); app.launch()
        app.tabBars.buttons["采集"].tap()
        XCTAssertTrue(app.staticTexts["S_UI_TEST · 0/120条合格"].waitForExistence(timeout:8))
    }
    func testCalibrationResultDetailsWithInMemoryFixture() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","--calibration-ui-fixture"]
        addUIInterruptionMonitor(withDescription:"System Bluetooth prompt") { alert in
            for title in ["允许","Allow","好","OK"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        app.launch(); XCTAssertTrue(app.tabBars.buttons["设置"].waitForExistence(timeout:15))
        app.tabBars.buttons["设置"].tap()
        let results = app.buttons["calibrationResults"]
        for _ in 0..<5 { if results.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(results.isHittable); results.tap()
        let device = app.buttons["calibrationResult_UI_CALIBRATION"]
        XCTAssertTrue(device.waitForExistence(timeout:5)); device.tap()
        XCTAssertTrue(app.navigationBars["校准结果详情"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["保存后静态复核通过"].exists)
        XCTAssertTrue(app.staticTexts["+0.01000"].exists)
        attach(app,"校准结果与三轴变化量（模拟数据）")
        app.terminate()
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot:app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testParallelCalibrationShowsIndependentLiveDeviceStates() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","--parallel-calibration-ui-fixture"]
        addUIInterruptionMonitor(withDescription:"System Bluetooth prompt") { alert in
            for title in ["允许","Allow","好","OK"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        app.launch(); XCTAssertTrue(app.tabBars.buttons["设置"].waitForExistence(timeout:15)); app.tabBars.buttons["设置"].tap()
        let results = app.buttons["calibrationResults"]
        for _ in 0..<6 { if results.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(results.isHittable); results.tap()
        XCTAssertTrue(app.buttons["停止本批全部校准"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["保存后静态复核通过"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["该设备断线；其他设备继续"].exists)
        attach(app,"并行校准成功与单台失败（模拟数据）")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["保持不动，独立等待保存"].firstMatch.exists)
        attach(app,"并行校准逐台独立状态（模拟数据）")
        app.terminate()
    }
}
