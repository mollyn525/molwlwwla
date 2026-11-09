import XCTest

/// Diagnostic collection only: a pass means evidence was captured, not that user interaction passed.
final class MonitorInputDiagnostics: XCTestCase {
    func testNativeTouchPath() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","--monitor-touch-probe","--ui-storage-id="+UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["liveMonitor"].waitForExistence(timeout:15))
        app.buttons["liveMonitor"].tap()
        XCTAssertTrue(app.staticTexts["Magnetic Field (a.u.)"].waitForExistence(timeout:5))
        func record(_ stage: String) {
            app.buttons["monitorProbeInspect"].tap()
            let value = app.staticTexts["monitorProbeReport"].label
            let state = stage+"\n"+value+"\nmag="+String(app.staticTexts["Magnetic Field (a.u.)"].exists)+" orientation="+String(app.staticTexts["Orientation (°)"].exists)
            let text = XCTAttachment(string:state); text.name=stage; text.lifetime = .keepAlways; add(text)
            let shot = XCTAttachment(screenshot:app.screenshot());shot.name=stage;shot.lifetime = .keepAlways;add(shot)
        }
        record("A before touch")
        let picker = app.segmentedControls.firstMatch
        picker.buttons["Orientation"].tap()
        record("B after ordinary tap")
        if !app.staticTexts["Orientation (°)"].exists {
            picker.buttons["Orientation"].press(forDuration:0.2)
            record("C after 200ms press")
        }
        if !app.staticTexts["Orientation (°)"].exists {
            picker.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.5))
                .press(forDuration:0.15,thenDragTo:picker.coordinate(withNormalizedOffset:CGVector(dx:0.75,dy:0.5)))
            record("D after native drag")
        }
        if !app.staticTexts["Orientation (°)"].exists {
            app.buttons["monitorProbeEvent"].tap()
            record("E programmatic diagnostic only")
        }
        app.terminate()
    }
}

