//
//  ToolPaletteView.swift
//  openshape3d
//
//  Floating left tool palette, Shapr3D style. Sections grow as features land.
//

import SwiftUI

struct ToolPaletteView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(spacing: 14) {
            section("Sketch") {
                sketchButton("line.diagonal", label: "Line", tool: .line)
                sketchButton("rectangle", label: "Rect", tool: .rect)
                sketchButton("circle", label: "Circle", tool: .circle)
            }
            Divider().frame(width: 40)
            section("Solids") {
                toolButton("cube", label: "Box", spec: .box(width: 4, depth: 4, height: 4))
                toolButton("cylinder", label: "Cylinder", spec: .cylinder(radius: 2, height: 4))
                toolButton("circle.fill", label: "Sphere", spec: .sphere(radius: 2))
            }
            Divider().frame(width: 40)
            section("Combine") {
                booleanButton("plus.square.on.square", label: "Union", kind: .union)
                booleanButton("minus.square", label: "Subtract", kind: .subtract)
                booleanButton("square.on.square.intersection.dashed", label: "Intersect", kind: .intersect)
            }
            Divider().frame(width: 40)
            section("Edit") {
                Button {
                    viewModel.deleteSelection()
                } label: {
                    paletteIcon("trash", label: "Delete")
                }
                .disabled(viewModel.selection.isEmpty)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func toolButton(_ systemImage: String, label: String, spec: PrimitiveSpec) -> some View {
        let isArmed: Bool = {
            if case .placingPrimitive(let current) = viewModel.mode {
                return current == spec
            }
            return false
        }()
        return Button {
            viewModel.armPrimitive(spec)
        } label: {
            paletteIcon(systemImage, label: label)
                .foregroundStyle(isArmed ? Color.orange : Color.primary)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isArmed ? Color.orange.opacity(0.15) : Color.clear)
        )
    }

    private func booleanButton(_ systemImage: String, label: String, kind: BooleanKind) -> some View {
        let isArming: Bool = {
            if case .pickingBooleanTool(let current, _) = viewModel.mode {
                return current == kind
            }
            return false
        }()
        return Button {
            if isArming {
                viewModel.cancelBooleanPicking()
            } else {
                viewModel.armBoolean(kind)
            }
        } label: {
            paletteIcon(systemImage, label: label)
                .foregroundStyle(isArming ? Color.purple : Color.primary)
        }
        .disabled(viewModel.selection.count != 1 && !isArming)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isArming ? Color.purple.opacity(0.15) : Color.clear)
        )
    }

    private func sketchButton(_ systemImage: String, label: String, tool: SketchTool) -> some View {
        let isActive: Bool = {
            if case .sketching(_, let current) = viewModel.mode {
                return current == tool
            }
            return false
        }()
        return Button {
            viewModel.startSketch(tool: tool)
        } label: {
            paletteIcon(systemImage, label: label)
                .foregroundStyle(isActive ? Color.blue : Color.primary)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.blue.opacity(0.15) : Color.clear)
        )
    }

    private func paletteIcon(_ systemImage: String, label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .frame(width: 44, height: 30)
            Text(label)
                .font(.system(size: 9))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
