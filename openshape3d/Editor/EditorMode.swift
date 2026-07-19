//
//  EditorMode.swift
//  openshape3d
//

import Foundation

enum SketchTool: String, CaseIterable {
    case line
    case rect
    case circle
    case arc
    case ellipse
    case polygon
    /// Tap-to-trim: no drawing; taps delete the entity span under them.
    case trim
}

enum EditorMode: Equatable {
    case idle
    /// A legacy primitive body is selected with editable dimensions.
    case editingPrimitive(BodyID)
    /// A whole body is selected (double-tap); move gizmo shown.
    case selected(BodyID)
    /// A planar face is selected (single tap on a body); push/pull it.
    case faceSelected(BodyID)
    /// A sketch tool is armed but no plane is chosen yet: the origin plane
    /// tiles are shown; tapping one (or a face/construction plane/the ground)
    /// starts the sketch there.
    case pickingSketchPlane(tool: SketchTool)
    /// Sketching on a plane with the given tool.
    case sketching(SketchID, tool: SketchTool)
    /// Pulling a profile into a solid (extrude or revolve tool active).
    case extruding
    /// Revolve armed: waiting for a tap on a sketch line to use as the axis.
    case pickingRevolveAxis
    /// Waiting for the second body of a boolean operation.
    case pickingBooleanTool(BooleanKind, target: BodyID)
    /// Measure tool: taps pick notable points; two picks show a distance.
    case measuring

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

/// Manual boolean-result override for the extrude/revolve commit (Shapr3D's
/// Boolean badge). `.auto` keeps the sample-point behavior.
enum BooleanOverride: String, CaseIterable {
    case auto = "Auto"
    case newBody = "New Body"
    case union = "Union"
    case subtract = "Subtract"
    case intersect = "Intersect"
}
