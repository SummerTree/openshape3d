//
//  SketchConstraintOverlay.swift
//  openshape3d
//
//  On-canvas constraint glyphs (plan §C3). Each symbolic constraint draws a
//  small code badge at its location (a relationship has no geometry of its own,
//  so the anchor is the average of its operand points, projected from world
//  space each camera move via `cameraEpoch`). Tapping a glyph selects the
//  constraint (blue highlight); the palette / Delete key then removes it
//  (undoable) and re-solves. Mirrors `SketchDimensionOverlay`.
//

import SwiftUI

struct SketchConstraintOverlay: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        // Reproject whenever the camera moves.
        let _ = viewModel.cameraEpoch
        if viewModel.mode.isSketching {
            ZStack(alignment: .topLeading) {
                ForEach(viewModel.sketchConstraintGlyphs) { glyph in
                    glyphView(glyph)
                }
            }
            .allowsHitTesting(true)
            // The Metal viewport is full-bleed; a SwiftUI overlay is safe-area
            // inset by default, which would draw every projected point ~85pt
            // below the geometry it annotates.
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func glyphView(_ glyph: EditorViewModel.SketchConstraintGlyph) -> some View {
        if let anchor = viewModel.cameraControl?.worldToScreenPoint(glyph.worldAnchor) {
            let selected = viewModel.selectedConstraintID == glyph.id
            // Fan out glyphs that share an anchor so each stays tappable.
            let offset = CGFloat(glyph.slot) * 22
            Button {
                viewModel.selectConstraint(glyph.id)
            } label: {
                Text(glyph.code)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selected ? Color.white : Color.blue)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(2)
                    .background(
                        selected ? Color.blue : Color(.systemBackground).opacity(0.9),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.blue, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .position(x: anchor.x, y: anchor.y + offset)
            .accessibilityIdentifier("ConstraintGlyph")
        }
    }
}
