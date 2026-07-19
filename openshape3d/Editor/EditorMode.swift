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
    /// Text (plan §B7, spec §1.12): taps place the text dialog's glyph
    /// outlines at the tapped point.
    case text
    /// Project (plan §B8, spec §1.13 v1): taps on a visible body flatten its
    /// feature edges onto the active sketch plane.
    case project
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
    /// Sweep armed: taps on open sketch entities (lines/arcs) chain into the
    /// sweep path.
    case pickingSweepPath
    /// Loft armed: taps on profile fills append loft sections in order.
    case pickingLoftProfiles
    /// Waiting for the second body of a boolean operation.
    case pickingBooleanTool(BooleanKind, target: BodyID)
    /// Split armed: waiting for a cutter tap — a world/construction plane
    /// tile, or a sketch profile fill (through-extruded cutter).
    case pickingSplitCutter(target: BodyID)
    /// Pattern bar active (linear/circular); parameters live in
    /// `EditorViewModel.patternState`, instances preview as ghosts.
    case patterning
    /// Rotate Around Axis (spec §5.3): waiting for an axis pick (sketch line
    /// tap or a world-axis button), then live angle entry/drag.
    case rotatingAroundAxis
    /// Translate (spec §5.2): tap a source snap point, then a destination;
    /// the selection shifts by the exact delta.
    case translating
    /// Align v1 (spec §5.5): tap a snap point on the body to move, then the
    /// destination point; that body translates so the points coincide.
    case aligning
    /// Measure tool: taps pick notable points; two picks show a distance.
    case measuring
    /// Section View armed (spec §16.1): the plane tiles are shown; tapping a
    /// world/construction plane tile or a planar face sets the section plane.
    case pickingSectionPlane
    /// Insert Image (plan §B10, spec §6.3): picked image bytes are waiting in
    /// `EditorViewModel.pendingImageData`; the plane tiles are shown, and the
    /// tapped plane (ground when the tap misses every tile) hosts the image.
    case pickingImagePlane

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
