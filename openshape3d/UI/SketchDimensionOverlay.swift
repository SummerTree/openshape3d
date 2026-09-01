//
//  SketchDimensionOverlay.swift
//  openshape3d
//
//  Light SwiftUI annotation layer for sketch dimensions (plan §C2, spec §2.2).
//  Draws a thin annotation line between the dimension's reference points and a
//  value label at the segment midpoint (projected from world space each camera
//  move via `cameraEpoch`). Tapping a label opens an inline numeric field;
//  committing sets the driving value and re-solves the sketch. Supports inline
//  arithmetic ("25.4/2") through `ExpressionEvaluator`.
//

import SwiftUI

struct SketchDimensionOverlay: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        // Reproject whenever the camera moves.
        let _ = viewModel.cameraEpoch
        if viewModel.mode.isSketching {
            ZStack(alignment: .topLeading) {
                ForEach(viewModel.sketchDimensionLabels) { label in
                    labelView(label)
                }
            }
            .allowsHitTesting(true)
            // The Metal viewport is full-bleed; a SwiftUI overlay is safe-area
            // inset by default, which would draw every projected point ~85pt
            // below the geometry it annotates.
            .ignoresSafeArea()
        }
    }

    /// Screen position of the sketch selection gizmo's move handle, if one is
    /// up. A dimension label that lands on the handle must not swallow the
    /// drag that moves the selection — the handle is the primary control
    /// there, and the label can always be reached by nudging the selection.
    private var gizmoHandlePoint: CGPoint? {
        guard let centroid = viewModel.sketchSelectionCentroid,
              let plane = viewModel.activeSketch?.plane else { return nil }
        return project(plane.toWorld(centroid))
    }

    /// Points; roughly the handle's own touch target.
    private static let gizmoHandleRadius: CGFloat = 34

    /// Nudge a label clear of the gizmo handle rather than hiding it: for a
    /// single selected line the two coincide exactly (the handle sits at the
    /// centroid, which is also where the length reads), and suppressing the
    /// label there would make the dimension untappable precisely when it is
    /// most likely to be edited. Offsetting keeps both reachable.
    private func clearOfGizmo(_ point: CGPoint, along start: CGPoint,
                              _ end: CGPoint) -> CGPoint {
        guard let handle = gizmoHandlePoint,
              hypot(point.x - handle.x, point.y - handle.y) < Self.gizmoHandleRadius
        else { return point }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else {
            return CGPoint(x: point.x, y: point.y - Self.gizmoHandleRadius)
        }
        // Perpendicular to the dimension line, so the label still reads as
        // belonging to it.
        return CGPoint(x: point.x - dy / length * Self.gizmoHandleRadius,
                       y: point.y + dx / length * Self.gizmoHandleRadius)
    }

    @ViewBuilder
    private func labelView(_ label: EditorViewModel.SketchDimensionLabel) -> some View {
        if let anchor = project(label.worldAnchor),
           let start = project(label.worldStart),
           let end = project(label.worldEnd) {
            // Thin annotation line between the reference points.
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(Color.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .allowsHitTesting(false)

            if viewModel.editingDimension?.labelID == label.id {
                DimensionField(viewModel: viewModel)
                    .position(anchor)
            } else {
                // Stage-2 conflict attribution: a dimension the solver could
                // not satisfy paints red — dueling lengths are the archetypal
                // sketch conflict, and the value badge is where the user
                // looks first.
                let conflicting = label.dimensionID.map {
                    viewModel.sketchConflictAttribution.dimensionIDs.contains($0)
                } ?? false
                Button {
                    viewModel.beginDimensionEdit(label)
                } label: {
                    Text(label.text)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(conflicting ? Color.red
                                        : label.dimensionID == nil
                                        ? Color.blue.opacity(0.4) : Color.blue,
                                        lineWidth: conflicting ? 2 : 1)
                        )
                        .foregroundStyle(conflicting ? Color.red
                                         : label.dimensionID == nil
                                         ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
                .position(clearOfGizmo(anchor, along: start, end))
                .accessibilityIdentifier(
                    conflicting ? "DimensionLabelConflict" : "DimensionLabel")
            }
        }
    }

    private func project(_ world: SIMD3<Double>) -> CGPoint? {
        viewModel.cameraControl?.worldToScreenPoint(world)
    }
}

/// The inline numeric editor shown in place of a dimension label while editing.
private struct DimensionField: View {
    @Bindable var viewModel: EditorViewModel
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .frame(width: 74)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { viewModel.commitDimensionEdit(text) }
                .accessibilityIdentifier("DimensionField")
            Button {
                viewModel.commitDimensionEdit(text)
            } label: {
                Image(systemName: "checkmark.circle.fill")
            }
            .accessibilityIdentifier("DimensionCommit")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue, lineWidth: 1))
        .onAppear {
            text = viewModel.editingDimension?.text ?? ""
            focused = true
        }
    }
}
