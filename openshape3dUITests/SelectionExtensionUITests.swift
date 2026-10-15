//
//  SelectionExtensionUITests.swift
//  openshape3dUITests
//
//  Settings ▸ Selection Extension ▸ Click Adds (spec §8.1): each tap on a
//  body adds it to the selection; a tap on empty space clears. Two boxes
//  are built through the DEBUG agent bridge, then tapped for real.
//

import XCTest

final class SelectionExtensionUITests: XCTestCase {

    private let port = "8933"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    /// POST /v1/exec or /v1/command, or GET /v1/state, synchronously.
    private func call(_ path: String, _ body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        var result: [String: Any] = [:]
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        return result
    }

    private func selectionCount() throws -> Int {
        (try call("/v1/state")["selection"] as? [Any])?.count ?? -1
    }

    func testClickAddsToTheSelection() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OS3D_FRESH"] = "1"
        app.launchEnvironment["OS3D_RESET_STORE"] = "1"
        app.launchEnvironment["OS3D_AGENT"] = "1"
        app.launchEnvironment["OS3D_AGENT_PORT"] = port
        app.launchArguments += ["-os3d.selectionExtension", "click"]
        app.launch()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 10))

        // Two 20 mm boxes side by side, seen from the top.
        var replies: [String] = []
        for x in [-30.0, 30.0] {
            let sketch = try call("/v1/exec", ["op": "sketch.create"])
            let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
            _ = try call("/v1/exec", ["op": "sketch.addEntities", "args": ["sketchID": sketchID, "entities": [
                ["kind": "rect", "min": [x - 10, -10], "max": [x + 10, 10]],
            ]]])
            let reply = try call("/v1/exec", ["op": "feature.extrude",
                                              "args": ["sketchID": sketchID, "seedPoint": [x, 0], "distance": 10]])
            replies.append("\(reply["ok"] ?? "-") \(reply["error"] ?? "") \(reply["message"] ?? "")")
        }
        _ = try call("/v1/exec", ["op": "item.setHidden", "args": ["allSketches": true]])
        _ = try call("/v1/command", ["id": "view.top"])
        sleep(1)
        _ = try call("/v1/command", ["id": "view.fit"])
        sleep(1)
        XCTAssertEqual((try call("/v1/state")["bodies"] as? [Any])?.count, 2, replies.joined(separator: " | "))

        // Find the boxes on screen: the fitted top view puts them left and
        // right of the middle. Probe across the row until a tap selects.
        let row = 0.5
        var left: CGVector?, right: CGVector?
        for x in stride(from: 0.30, through: 0.48, by: 0.03) where left == nil {
            app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: row)).tap()
            if try selectionCount() == 1 { left = CGVector(dx: x, dy: row) }
        }
        let firstLeft = try XCTUnwrap(left, "a tap finds the left box")
        for x in stride(from: 0.70, through: 0.52, by: -0.03) where right == nil {
            app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: row)).tap()
            if try selectionCount() == 2 { right = CGVector(dx: x, dy: row) }
        }
        XCTAssertNotNil(right, "with Click Adds, the second box joins the first")
        _ = firstLeft

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "selection-extension-two-selected"; shot.lifetime = .keepAlways; add(shot)
        // A tap on empty space (a corner, clear of the boxes and of the move
        // gizmo that sits between them) clears.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        let state = try call("/v1/state")
        XCTAssertEqual((state["selection"] as? [Any])?.count, 0, "empty space deselects; mode \(state["mode"] ?? "?")")
    }
}
