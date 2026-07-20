//
//  ToolPaletteView.swift
//  openshape3d
//
//  Floating left tool palette, Shapr3D style. Sections grow as features land.
//

import SwiftUI

struct ToolPaletteView: View {
    @Bindable var viewModel: EditorViewModel

    /// The palette grew past shorter (portrait) screens with the Phase B
    /// tools: render plain when it fits, otherwise inside a scroll view so
    /// every tool stays reachable.
    var body: some View {
        ViewThatFits(in: .vertical) {
            paletteContent
            ScrollView(.vertical, showsIndicators: false) {
                paletteContent
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private var paletteContent: some View {
        VStack(spacing: 14) {
            section("Sketch") {
                sketchButton("line.diagonal", label: "Line", tool: .line)
                sketchButton("rectangle", label: "Rect", tool: .rect)
                sketchButton("circle", label: "Circle", tool: .circle)
                sketchButton("point.topleft.down.to.point.bottomright.curvepath", label: "Arc", tool: .arc)
                sketchButton("oval", label: "Ellipse", tool: .ellipse)
                sketchButton("hexagon", label: "Polygon", tool: .polygon)
                sketchButton("scissors", label: "Trim", tool: .trim)
                sketchButton("textformat", label: "Text", tool: .text)
                sketchButton("square.on.square.dashed", label: "Project", tool: .project)
                makeSymbolButton
                insertSymbolMenu
                constraintsMenu
                dimensionButton
            }
            Divider().frame(width: 40)
            section("Combine") {
                booleanButton("plus.square.on.square", label: "Union", kind: .union)
                booleanButton("minus.square", label: "Subtract", kind: .subtract)
                booleanButton("square.on.square.intersection.dashed", label: "Intersect", kind: .intersect)
            }
            Divider().frame(width: 40)
            section("Transform") {
                Button {
                    viewModel.beginScaleEntry()
                } label: {
                    paletteIcon("arrow.down.left.and.arrow.up.right", label: "Scale")
                        .foregroundStyle(viewModel.scaleEntryActive ? Color.blue : Color.primary)
                }
                .disabled(viewModel.selection.isEmpty)

                Menu {
                    ForEach(
                        Array(viewModel.mirrorPlaneOptions.enumerated()), id: \.offset
                    ) { _, option in
                        Button(option.label) {
                            viewModel.mirrorSelection(across: option.plane)
                        }
                    }
                } label: {
                    paletteIcon("rectangle.on.rectangle", label: "Mirror")
                        .foregroundStyle(Color.primary)
                }
                .disabled(viewModel.selection.count != 1)

                translateButton
                rotateAxisButton
                alignButton
                splitButton
                patternButton
            }
            Divider().frame(width: 40)
            section("Edit") {
                selectButton
                measureButton
                materialButton
                constructionButton
                Button {
                    viewModel.deleteSelection()
                } label: {
                    paletteIcon("trash", label: "Delete")
                }
                .disabled(
                    viewModel.mode.isSketching
                        ? (viewModel.selectedSketchEntityIDs.isEmpty
                           && !viewModel.hasSketchGlyphSelection)
                        : viewModel.selection.isEmpty && viewModel.selectedImage == nil
                )
                .accessibilityIdentifier("DeleteButton")
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
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

    /// Translate (plan §B6, spec §5.2): point-to-point snap move.
    private var translateButton: some View {
        let isActive: Bool = {
            if case .translating = viewModel.mode { return true }
            return false
        }()
        return Button {
            if isActive {
                viewModel.cancelTranslate()
            } else {
                viewModel.beginTranslatePick()
            }
        } label: {
            paletteIcon("arrow.up.and.down.and.arrow.left.and.right", label: "Translate")
                .foregroundStyle(isActive ? Color.purple : Color.primary)
        }
        .disabled(viewModel.selection.isEmpty && !isActive)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.purple.opacity(0.15) : Color.clear)
        )
        .accessibilityIdentifier("TranslateButton")
    }

    /// Rotate Around Axis (plan §B6, spec §5.3).
    private var rotateAxisButton: some View {
        let isActive: Bool = {
            if case .rotatingAroundAxis = viewModel.mode { return true }
            return false
        }()
        return Button {
            if isActive {
                viewModel.cancelRotateAxis()
            } else {
                viewModel.beginRotateAxisPick()
            }
        } label: {
            paletteIcon("arrow.clockwise", label: "Rotate")
                .foregroundStyle(isActive ? Color.purple : Color.primary)
        }
        .disabled(viewModel.selection.isEmpty && !isActive)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.purple.opacity(0.15) : Color.clear)
        )
        .accessibilityIdentifier("RotateAxisButton")
    }

    /// Align v1 (plan §B6, spec §5.5): dot-onto-dot snap-point mating.
    private var alignButton: some View {
        let isActive: Bool = {
            if case .aligning = viewModel.mode { return true }
            return false
        }()
        return Button {
            if isActive {
                viewModel.cancelAlign()
            } else {
                viewModel.beginAlignPick()
            }
        } label: {
            paletteIcon("point.3.connected.trianglepath.dotted", label: "Align")
                .foregroundStyle(isActive ? Color.purple : Color.primary)
        }
        .disabled(viewModel.session.document.bodies.count < 2 && !isActive)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.purple.opacity(0.15) : Color.clear)
        )
        .accessibilityIdentifier("AlignButton")
    }

    /// Split Body (plan §B3): arms the cutter pick for the selected body.
    private var splitButton: some View {
        let isArming: Bool = {
            if case .pickingSplitCutter = viewModel.mode { return true }
            return false
        }()
        return Button {
            if isArming {
                viewModel.cancelSplitCutterPick()
            } else {
                viewModel.beginSplitCutterPick()
            }
        } label: {
            paletteIcon("square.split.1x2", label: "Split")
                .foregroundStyle(isArming ? Color.purple : Color.primary)
        }
        .disabled(viewModel.selection.count != 1 && !isArming)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isArming ? Color.purple.opacity(0.15) : Color.clear)
        )
        .accessibilityIdentifier("SplitButton")
    }

    /// Pattern (plan §B5): opens the pattern bar for the selected body or the
    /// armed extrude profile.
    private var patternButton: some View {
        let isActive: Bool = {
            if case .patterning = viewModel.mode { return true }
            return false
        }()
        return Button {
            if isActive {
                viewModel.cancelPattern()
            } else {
                viewModel.beginPattern()
            }
        } label: {
            paletteIcon("square.grid.3x3", label: "Pattern")
                .foregroundStyle(isActive ? Color.blue : Color.primary)
        }
        .disabled(!viewModel.canBeginPattern && !isActive)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.blue.opacity(0.15) : Color.clear)
        )
        .accessibilityIdentifier("PatternButton")
    }

    /// Select mode (plan §B13, spec §8.2): marquee drags + additive taps.
    private var selectButton: some View {
        Button {
            viewModel.toggleSelectMode()
        } label: {
            paletteIcon("cursorarrow.and.square.on.square.dashed", label: "Select")
                .foregroundStyle(viewModel.selectModeActive ? Color.blue : Color.primary)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(viewModel.selectModeActive ? Color.blue.opacity(0.15) : Color.clear)
        )
        .accessibilityIdentifier("SelectModeButton")
    }

    /// Point-to-point Measure tool (spec §16.3): toggles measuring mode.
    private var measureButton: some View {
        let isMeasuring: Bool = {
            if case .measuring = viewModel.mode { return true }
            return false
        }()
        return Button {
            viewModel.toggleMeasure()
        } label: {
            paletteIcon("ruler", label: "Measure")
                .foregroundStyle(isMeasuring ? Color.blue : Color.primary)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isMeasuring ? Color.blue.opacity(0.15) : Color.clear)
        )
        .accessibilityIdentifier("MeasureButton")
    }

    /// Material sheet (plan §B15): assign a preset/custom appearance to the
    /// selected body or multi-selection.
    private var materialButton: some View {
        Button {
            viewModel.showMaterialSheet = true
        } label: {
            paletteIcon("paintpalette", label: "Material")
        }
        .disabled(viewModel.selection.isEmpty)
        .accessibilityIdentifier("MaterialButton")
    }

    /// Make Construction / Make Regular (plan §B9, spec §3.3): bulk toggle
    /// on the selected sketch entities.
    private var constructionButton: some View {
        let isOn = viewModel.selectionIsConstruction
        return Button {
            viewModel.toggleConstructionOnSelection()
        } label: {
            paletteIcon("square.dashed", label: "Construct")
                .foregroundStyle(isOn ? Color.blue : Color.primary)
        }
        .disabled(!viewModel.mode.isSketching || viewModel.selectedSketchEntityIDs.isEmpty)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isOn ? Color.blue.opacity(0.15) : Color.clear)
        )
        .accessibilityIdentifier("ConstructionButton")
    }

    /// Make Symbol (plan §B16, spec §1.16): capture the selected sketch
    /// entities as a named reusable group (name prompt lives in EditorView).
    private var makeSymbolButton: some View {
        Button {
            viewModel.showMakeSymbolPrompt = true
        } label: {
            paletteIcon("rectangle.stack.badge.plus", label: "Symbol")
        }
        .disabled(!viewModel.canMakeSymbol)
        .accessibilityIdentifier("MakeSymbolButton")
    }

    /// Insert Symbol (plan §B16): lists the document's symbols; choosing one
    /// arms tap-to-place until Done/Esc exits.
    private var insertSymbolMenu: some View {
        let armed = viewModel.pendingSymbolID != nil
        return Menu {
            ForEach(viewModel.session.document.symbols) { symbol in
                Button(symbol.name) {
                    viewModel.beginInsertSymbol(symbol.id)
                }
            }
        } label: {
            paletteIcon("rectangle.stack", label: "Insert")
                .foregroundStyle(armed ? Color.blue : Color.primary)
        }
        .disabled(!viewModel.mode.isSketching || viewModel.session.document.symbols.isEmpty)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(armed ? Color.blue.opacity(0.15) : Color.clear)
        )
        .accessibilityIdentifier("InsertSymbolMenu")
    }

    /// Constraints menu (plan §C3, spec §3.2): adaptive — each entry is
    /// enabled only when the current sketch selection supports it. Applying
    /// re-solves the sketch and commits the moved geometry in one undo step.
    private var constraintsMenu: some View {
        Menu {
            constraintItem("Coincident", .coincident, key: "c")
            constraintItem("Horizontal", .horizontal, key: "h")
            constraintItem("Vertical", .vertical, key: "v")
            constraintItem("Parallel", .parallel, key: "p")
            constraintItem("Perpendicular", .perpendicular, key: "e")
            constraintItem("Equal Length", .equalLength, key: "q")
            constraintItem("Equal Radius", .equalRadius, key: "r")
            constraintItem("Concentric", .concentric, key: "o")
            constraintItem("Midpoint", .midpoint, key: "m")
            constraintItem("Symmetric", .symmetric, key: "y")
            constraintItem("Tangent", .tangent, key: "t")
            constraintItem("Colinear", .colinear, key: "l")
            constraintItem("Lock", .fixed, key: "k")

            Divider()
            Button("Delete Constraint") {
                viewModel.deleteSelectedConstraint()
            }
            .disabled(viewModel.selectedConstraintID == nil)
            .accessibilityIdentifier("DeleteConstraintItem")

            Divider()
            Button("Auto-Constrain Settings…") {
                viewModel.showConstraintSettings = true
            }
            .accessibilityIdentifier("ConstraintSettingsItem")
        } label: {
            paletteIcon("link", label: "Constrain")
                .foregroundStyle(Color.primary)
        }
        .disabled(!viewModel.mode.isSketching)
        .accessibilityIdentifier("ConstraintsMenu")
    }

    /// Dimension action (plan §C2, spec §2.2): opens the inline numeric field
    /// for the current selection's candidate dimension (length/radius/angle, or
    /// a pairwise distance between two points/lines). Committing adds a driving
    /// dimension and re-solves.
    private var dimensionButton: some View {
        Button {
            viewModel.beginDimensionForSelection()
        } label: {
            paletteIcon("ruler", label: "Dimension")
                .foregroundStyle(Color.primary)
        }
        .disabled(!viewModel.canDimensionSelection)
        .accessibilityIdentifier("DimensionButton")
    }

    /// One constraint-kind entry: leading glyph (from
    /// `EditorViewModel.constraintCode`) + name, a ⇧-modified hardware-keyboard
    /// shortcut, enabled only when the current selection supports the kind.
    /// A `Text` label with the glyph prefixed to the title renders reliably in
    /// a `Menu` (the icon slot of `Label` drops non-`Image` content there).
    private func constraintItem(_ label: String, _ kind: SketchConstraintKind, key: KeyEquivalent) -> some View {
        Button {
            viewModel.applyConstraint(kind)
        } label: {
            Text("\(EditorViewModel.constraintCode(kind))   \(label)")
        }
        .keyboardShortcut(key, modifiers: [.shift])
        .disabled(!viewModel.canApplyConstraint(kind))
        .accessibilityIdentifier("Constraint_\(label.replacingOccurrences(of: " ", with: ""))")
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
