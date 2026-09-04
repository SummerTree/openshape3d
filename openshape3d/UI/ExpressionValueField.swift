//
//  ExpressionValueField.swift
//  openshape3d
//
//  A bar value field that holds TEXT and applies it LIVE: every keystroke
//  that evaluates (the evaluator's arithmetic — "1*0+23", "25.4/2") lands in
//  the bound millimetre value, so the tool's preview follows the typing and
//  the bar's Apply button can never commit a stale number.
//
//  Born from the fillet bar (2026-09-04): its formatted numeric field flushed
//  only on Return, could not take an expression, and a hardware keyboard has
//  no select-all — so "type 23, tap Apply" filleted at the field's old 1 mm
//  while showing "1*0+23". The extrude bar's Distance field had the same bug
//  the day before (gotcha 37) and got the same cure.
//

import SwiftUI

struct ExpressionValueField: View {
    var placeholder: String
    /// The model value in millimetres.
    @Binding var mm: Double
    var width: CGFloat = 64
    var identifier: String
    /// Return in the field, after the value is applied.
    var onSubmit: () -> Void = {}

    @State private var text = ""
    @FocusState private var focused: Bool

    private var unit: DisplayUnit { AppSettings.shared.unit }

    private func display(_ mm: Double) -> String {
        let shown = unit.display(fromMM: mm)
        if abs(shown - shown.rounded()) < 1e-6 { return String(Int(shown.rounded())) }
        return String(format: "%g", (shown * 1000).rounded() / 1000)
    }

    private func apply(_ string: String) -> Bool {
        guard let typed = ExpressionEvaluator.evaluate(string) else { return false }
        let value = unit.mm(fromDisplay: typed)
        if abs(value - mm) > 1e-9 { mm = value }
        return true
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.numbersAndPunctuation)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onAppear { text = display(mm) }
            // A drag on the tool's handle moves the value under the field;
            // mirror it unless the person is mid-edit.
            .onChange(of: mm) { _, new in
                if !focused { text = display(new) }
            }
            .onChange(of: text) { _, new in
                if focused { _ = apply(new) }
            }
            .onSubmit {
                _ = apply(text)
                onSubmit()
            }
            .accessibilityIdentifier(identifier)
    }
}
