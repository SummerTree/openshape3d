//
//  MoveDistanceOverlay.swift
//  openshape3d
//
//  The move gizmo's value pill (Shapr3D §5.1). It rides the handle the user
//  grabbed: while a drag is in flight it reads out the distance travelled, and
//  tapping an arrow (instead of dragging it) turns it into a text field so an
//  exact distance can be typed — Enter commits the move, ✕ cancels.
//
//  Sibling of `ExtrudeGizmoOverlay`, which does the same job for push/pull.
//

import SwiftUI
import simd

struct MoveDistanceOverlay: View {
    @Bindable var viewModel: EditorViewModel

    /// How far off the handle the pill floats, in points — clear of the
    /// arrowhead (which is ~30pt tall) so it never covers what it measures.
    private static let float: CGFloat = 52

    var body: some View {
        // Reproject whenever the camera moves.
        let _ = viewModel.cameraEpoch
        if let label = viewModel.moveDistanceLabel, let anchor = anchor(for: label.part) {
            ZStack {
                if label.isEditable {
                    MoveDistanceField(viewModel: viewModel, part: label.part)
                        .position(anchor)
                } else {
                    Text(label.text)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.blue, lineWidth: 1.5))
                        .foregroundStyle(Color.blue)
                        .position(anchor)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("MoveDistanceValue")
                }
            }
            // `worldToScreenPoint` is in full-screen (MTKView) coordinates, so
            // the overlay must span the full screen too — otherwise the safe
            // area shifts every `.position` off the geometry it annotates.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }

    /// Screen point for the pill: past the arrowhead along the axis, or just
    /// below-right of a plane tile.
    private func anchor(for part: GizmoPart) -> CGPoint? {
        guard let origin = viewModel.gizmoOrigin,
              let control = viewModel.cameraControl else { return nil }
        let scale = control.gizmoWorldScale(at: origin)
        let project: (SIMD3<Float>) -> CGPoint? = { local in
            let world = origin + local * scale
            return control.worldToScreenPoint(
                SIMD3(Double(world.x), Double(world.y), Double(world.z)))
        }
        guard let center = project(.zero) else { return nil }
        if part.isArrow {
            guard let tip = GizmoScreenLayout.axisAnchor(part, project: project) else {
                return nil
            }
            let dx = tip.x - center.x, dy = tip.y - center.y
            let len = hypot(dx, dy)
            // A foreshortened axis has no useful on-screen direction — drop the
            // pill straight down off the tip instead of jittering with it.
            guard len > 12 else {
                return CGPoint(x: tip.x, y: tip.y + Self.float)
            }
            return CGPoint(x: tip.x + dx / len * Self.float,
                           y: tip.y + dy / len * Self.float)
        }
        guard let tile = GizmoScreenLayout.planeAnchor(part, project: project) else {
            return nil
        }
        return CGPoint(x: tile.x, y: tile.y + Self.float)
    }
}

/// The inline field shown when an arrow is tapped: type a distance, Enter to
/// move exactly that far along the axis.
private struct MoveDistanceField: View {
    @Bindable var viewModel: EditorViewModel
    let part: GizmoPart
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(part.axisName)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            TextField(AppSettings.shared.unit.symbol, text: $text)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .frame(width: 74)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { viewModel.commitMoveDistance(text) }
                .accessibilityIdentifier("MoveDistanceField")
            Button {
                viewModel.cancelAxisDistanceEntry()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("MoveDistanceCancel")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.blue, lineWidth: 1.5))
        .onAppear {
            text = ""
            focused = true
        }
    }
}
