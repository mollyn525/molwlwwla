import XCTest

final class ExportFilesUITests: XCTestCase {
    func testExistingExportsShareSaveAndConfirmedDeletion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","--ui-storage-id="+UUID().uuidString,"--export-files-ui-fixture"]
        addUIInterruptionMonitor(withDescription:"Bluetooth prompt") { alert in
            for title in ["允许","Allow","好","OK"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["记录"].waitForExistence(timeout:15)); app.tabBars.buttons["记录"].tap()
        let history = app.buttons["exportFiles"]
        for _ in 0..<3 { if history.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(history.isHittable); history.tap()
        XCTAssertTrue(app.navigationBars["已导出文件"].waitForExistence(timeout:5))
        let complete = "fixture-complete.zip"
        func reveal(_ element: XCUIElement) {
            for _ in 0..<4 { if element.isHittable { return }; app.swipeUp() }
        }
        let share = app.buttons["shareExport-"+complete]; reveal(share); XCTAssertTrue(share.isHittable); share.tap()
        XCTAssertTrue(app.otherElements["exportShareSheet"].waitForExistence(timeout:5) || app.buttons["拷贝"].exists || app.buttons["Copy"].exists)
        // Dismiss the system sheet using its native downward gesture.
        let close = app.buttons.matching(NSPredicate(format:"label == '关闭' OR label == 'Close'")).firstMatch
        if close.exists { close.tap() }
        else { app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.1)).press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.95))) }
        let save = app.buttons["saveExport-"+complete]; reveal(save); XCTAssertTrue(save.isHittable); save.tap()
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout:5)); cancel.tap()
        let remove = app.buttons["deleteExport-"+complete]; reveal(remove); remove.tap()
        let dialog = app.alerts["删除打包文件？"]
        XCTAssertTrue(dialog.waitForExistence(timeout:5)); XCTAssertTrue(dialog.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","原始采集")).firstMatch.exists)
        dialog.buttons["取消"].tap(); XCTAssertTrue(remove.exists)
        remove.tap(); dialog.buttons["删除此文件"].tap()
        XCTAssertFalse(app.buttons["shareExport-"+complete].exists)
        XCTAssertTrue(app.staticTexts["未完成的打包文件"].exists)
        XCTAssertFalse(app.buttons["shareExport-fixture.partial.zip"].exists)
        let attachment = XCTAttachment(screenshot:app.screenshot()); attachment.name = "导出文件管理与未完成文件"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
