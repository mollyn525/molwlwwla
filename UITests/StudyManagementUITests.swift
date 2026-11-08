import XCTest

final class StudyManagementUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","--ui-storage-id="+UUID().uuidString]+extra
        addUIInterruptionMonitor(withDescription:"Bluetooth prompt") { alert in
            for title in ["允许","Allow","好","OK"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["采集"].waitForExistence(timeout:15))
        app.tabBars.buttons["采集"].tap()
        return app
    }
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 { if element.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout:5)); XCTAssertTrue(element.isHittable); element.tap()
    }
    func testSubjectTrashRestorePurgeAndRelaunch() {
        continueAfterFailure = false
        let app = launch()
        for name in ["DELETE_ME","KEEP_ME"] {
            app.buttons["新建受试者任务"].tap()
            let dialog = app.alerts["新建匿名受试者任务"]
            XCTAssertTrue(dialog.waitForExistence(timeout:5))
            dialog.textFields.firstMatch.tap(); dialog.textFields.firstMatch.typeText(name)
            dialog.buttons["建立"].tap()
        }
        tap(app.buttons["manageSubjects"],in:app)
        tap(app.buttons["trashSubject_DELETE_ME"],in:app)
        app.buttons["移入最近删除"].tap()
        XCTAssertTrue(app.buttons["restoreSubject_DELETE_ME"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["continueSubject_KEEP_ME"].exists)
        XCTAssertFalse(app.buttons["continueSubject_DELETE_ME"].exists)
        app.terminate(); app.launch()
        app.tabBars.buttons["采集"].tap(); tap(app.buttons["manageSubjects"],in:app)
        tap(app.buttons["restoreSubject_DELETE_ME"],in:app)
        XCTAssertTrue(app.buttons["continueSubject_DELETE_ME"].waitForExistence(timeout:5))
        tap(app.buttons["trashSubject_DELETE_ME"],in:app); app.buttons["移入最近删除"].tap()
        tap(app.buttons["purgeSubject_DELETE_ME"],in:app)
        let confirm = app.alerts["彻底删除受试者记录？"]
        XCTAssertTrue(confirm.waitForExistence(timeout:5))
        XCTAssertFalse(confirm.buttons["彻底删除"].isEnabled)
        confirm.textFields.firstMatch.tap(); confirm.textFields.firstMatch.typeText("DELETE_ME")
        XCTAssertTrue(confirm.buttons["彻底删除"].isEnabled); confirm.buttons["彻底删除"].tap()
        XCTAssertTrue(app.staticTexts["最近删除为空"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["continueSubject_KEEP_ME"].exists)
        XCTAssertFalse(app.buttons["continueSubject_DELETE_ME"].exists)
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "合成受试者删除恢复与彻底删除"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
    }
    func testNotificationCenterKeepsWriterAndHomeEndsIt() {
        continueAfterFailure = false
        let app = launch(["--lifecycle-ui-fixture"])
        let probe = app.staticTexts["lifecycleProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout:10))
        func fields() -> [String] { probe.label.components(separatedBy:"|") }
        let before = fields(); XCTAssertEqual(before.count,5); XCTAssertEqual(before[4],"1")
        let start = app.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.01))
        start.press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.8)))
        let springboard = XCUIApplication(bundleIdentifier:"com.apple.springboard")
        let shot = XCTAttachment(screenshot:XCUIScreen.main.screenshot()); shot.name = "合成采集期间展开通知中心"; shot.lifetime = .keepAlways; add(shot)
        // A short, bounded dwell exercises the actual OS inactive phase.
        Thread.sleep(forTimeInterval:1.5)
        springboard.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.98))
            .press(forDuration:0.1,thenDragTo:springboard.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.25)))
        let continued = NSPredicate { _,_ in
            guard probe.exists else { return false }
            let p = fields()
            return p.count == 5 && p[0] == before[0] && p[4] == "1" && p[3] == "active" &&
                (Int(p[2]) ?? 0) > (Int(before[2]) ?? 0) && (Int(p[1]) ?? 0) > (Int(before[1]) ?? 0)
        }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:continued,object:nil)],timeout:10),.completed)
        XCTAssertTrue(app.buttons["recordingStop"].isEnabled)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(probe.waitForExistence(timeout:10))
        let ended = NSPredicate { _,_ in
            let p = fields(); return p.count == 5 && p[0] == before[0] && p[4] == "0"
        }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:ended,object:nil)],timeout:10),.completed)
        let final = XCTAttachment(screenshot:app.screenshot()); final.name = "进入后台后结束并保存合成记录"; final.lifetime = .keepAlways; add(final)
        app.terminate()
    }
}

