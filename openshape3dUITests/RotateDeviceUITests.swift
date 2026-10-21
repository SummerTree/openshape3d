//
//  RotateDeviceUITests.swift
//  openshape3dUITests
//
//  Not a test of the app: a way to turn a simulator on its side from a
//  script. `simctl` cannot rotate a device, but `XCUIDevice` can, and the
//  orientation outlives the test — so a recording made afterwards with
//  `simctl io recordVideo` is landscape. Used by
//  `scripts/scan_to_cad/demo_video.py` before a take.
//
//      xcodebuild test … -only-testing:openshape3dUITests/RotateDeviceUITests
//
//  `TEST_RUNNER_OS3D_ORIENTATION=portrait` turns it back.
//

import XCTest

final class RotateDeviceUITests: XCTestCase {

    func testRotateTheDevice() {
        let wanted = ProcessInfo.processInfo.environment["OS3D_ORIENTATION"] ?? "landscape"
        XCUIDevice.shared.orientation = wanted == "portrait" ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launch()
        // Give the window a moment to lay out on its side before the runner
        // tears the app down.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        sleep(2)
    }
}
