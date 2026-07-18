//
//  EditorMode.swift
//  openshape3d
//

import Foundation

enum SketchTool: String, CaseIterable {
    case line
    case rect
    case circle
}

enum EditorMode: Equatable {
    case idle
    /// A legacy primitive body is selected with editable dimensions.
    case editingPrimitive(BodyID)
    /// A whole body is selected (double-tap); move gizmo shown.
    case selected(BodyID)
    /// A planar face is selected (single tap on a body); push/pull it.
    case faceSelected(BodyID)
    /// Sketching on a plane with the given tool.
    case sketching(SketchID, tool: SketchTool)
    /// Pulling a profile into a solid.
    case extruding
    /// Waiting for the second body of a boolean operation.
    case pickingBooleanTool(BooleanKind, target: BodyID)

    var isSketching: Bool {
        if case .sketching = self { return true }
        return false
    }
}

enum BooleanKind: String {
    case union
    case subtract
    case intersect
}
