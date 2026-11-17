import XCTest

final class ExportFilesUITests: XCTestCase {
    private func openHistory() -> XCUIApplication {
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
        return app
    }
    private let complete = "fixture-complete.zip"
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        // XCUI can report a List row as hittable when only a few pixels sit
        // above the floating tab bar. Require the whole row in the content area.
        for _ in 0..<6 {
            let top = app.navigationBars.firstMatch.frame.maxY + 4
            let bottom = app.tabBars.firstMatch.frame.minY - 4
            let frame = element.frame
            if element.isHittable && frame.minY > top && frame.maxY < bottom { return }
            if frame.minY <= top { app.swipeDown() } else { app.swipeUp() }
        }
        XCTFail("Action row must be fully visible above the tab bar: \(element.frame)")
    }
    func testExistingExportCanBeSharedAgain() {
        let app = openHistory()
        let share = app.buttons["shareExport-"+complete]; reveal(share,in:app); share.tap()
        // iOS 26 replaces the activity controller's root and exposes actions as
        // cells. Verify the actual system container observed in its AX snapshot.
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout:10))
        XCTAssertTrue(app.cells["拷贝"].exists || app.cells["Copy"].exists)
        // Dismiss the system sheet using its native downward gesture.
        let close = app.buttons.matching(NSPredicate(format:"label == '关闭' OR label == 'Close'")).firstMatch
        if close.exists { close.tap() }
        else { app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.1)).press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.95))) }
        XCTAssertTrue(app.navigationBars["已导出文件"].waitForExistence(timeout:5))
        app.terminate()
    }
    func testSaveCopyPickerCancellationPreservesExport() {
        let app = openHistory()
        let save = app.buttons["saveExport-"+complete]; reveal(save,in:app); save.tap()
        let cancel = app.buttons.matching(NSPredicate(format:"label == '取消' OR label == 'Cancel'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout:10)); cancel.tap()
        XCTAssertTrue(app.navigationBars["已导出文件"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["shareExport-"+complete].exists)
        app.terminate()
    }
    func testOnlyConfirmedExportDeletionAndIncompleteMarker() {
        let app = openHistory()
        let remove = app.buttons["deleteExport-"+complete]; reveal(remove,in:app); remove.tap()
        let dialog = app.alerts["删除打包文件？"]
        XCTAssertTrue(dialog.waitForExistence(timeout:5)); XCTAssertTrue(dialog.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","原始采集")).firstMatch.exists)
        dialog.buttons["取消"].tap(); XCTAssertTrue(remove.exists)
        remove.tap(); dialog.buttons["删除此文件"].tap()
        XCTAssertFalse(app.buttons["shareExport-"+complete].exists)
        XCTAssertTrue(app.staticTexts["未完成的打包文件"].exists)
        XCTAssertFalse(app.buttons["shareExport-fixture.partial.zip"].exists)
        let attachment = XCTAttachment(screenshot:app.screenshot()); attachment.name = "导出文件管理与未完成文件"; attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
    }
}
