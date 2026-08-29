//
//  IO2UITests.swift
//  openshape3dUITests
//
//  Interchange chrome (plan §B14): the Export menu lists GLB/DXF/STEP (plus
//  the USDZ/AR Preview pair only where ModelIO can write USDZ — they hide
//  together), the OBJ/GLB options sheet offers the per-body toggle, and the
//  Import menu lists the DXF and STEP entries. The system file dialogs are
//  never driven — the DXF paths are unit-covered in IO2FlowTests, the STEP
//  ones in STEPKitTests.
//

import XCTest

final class IO2UITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testExportAndImportMenusListInterchangeFormats() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_DEBUG_SEED"] = "1"
        app.launch()

        // Export menu: the new interchange formats sit beside the old ones.
        let exportMenu = app.buttons["ExportMenu"]
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 10))
        exportMenu.tap()
        XCTAssertTrue(app.buttons["GLB"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["DXF"].exists)
        XCTAssertTrue(app.buttons["STL"].exists)
        XCTAssertTrue(app.buttons["OBJ"].exists)
        XCTAssertTrue(app.buttons["3MF"].exists)
        // STEP (spec §12.2) — the exact-B-rep export, queried by identifier
        // because its label is the same three letters as its file extension.
        XCTAssertTrue(app.buttons["ExportSTEP"].exists)
        // Graceful USDZ degradation: the USDZ entry and the AR Preview
        // button are both gated on the same support check, so they must
        // appear or hide together — never one without the other.
        XCTAssertEqual(
            app.buttons["USDZ"].exists,
            app.buttons["ARPreviewButton"].exists,
            "USDZ entry and AR Preview must hide together when unsupported"
        )

        // GLB opens the per-body options sheet; cancel without exporting.
        app.buttons["GLB"].tap()
        XCTAssertTrue(app.switches["ExportPerBodyToggle"].waitForExistence(timeout: 3))
        let cancel = app.buttons["MeshExportCancel"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertFalse(
            app.switches["ExportPerBodyToggle"].waitForExistence(timeout: 2),
            "Cancel should dismiss the mesh export options sheet"
        )

        // Import menu lists the DXF and STEP entries next to STL.
        let importMenu = app.buttons["ImportMenu"]
        XCTAssertTrue(importMenu.waitForExistence(timeout: 5))
        importMenu.tap()
        XCTAssertTrue(app.buttons["ImportDXF"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["ImportSTEP"].exists)
        XCTAssertTrue(app.buttons["STL File…"].exists)

        // Dismiss the menu by tapping empty viewport space; the editor
        // chrome must survive the whole tour (no crash).
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            .tap()
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 3))
        XCTAssertTrue(importMenu.exists)
    }
}
