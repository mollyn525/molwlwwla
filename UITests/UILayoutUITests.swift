import XCTest

final class UILayoutUITests: XCTestCase {
    func testMainPagesInLightAndAccessibleDarkAppearance() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let args = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","--ui-storage-id="+UUID().uuidString]
        app.launchArguments = args
        addUIInterruptionMonitor(withDescription:"Bluetooth prompt") { alert in
            for title in ["允许","Allow","好","OK"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["设备"].waitForExistence(timeout:15))
        for title in ["设备","采集","佩戴","记录","设置"] {
            app.tabBars.buttons[title].tap()
            attach(app,"整理后 · 浅色 · "+title)
        }
        app.terminate()
        app.launchArguments = args + ["--ui-dark-appearance","--ui-accessibility-type"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["设备"].waitForExistence(timeout:15))
        for title in ["设备","采集","设置"] {
            app.tabBars.buttons[title].tap()
            attach(app,"整理后 · 深色大字号 · "+title)
        }
        app.terminate()
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot:app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}

