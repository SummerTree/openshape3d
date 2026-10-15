//
//  KeyboardShortcutsView.swift
//  openshape3d
//
//  Settings ▸ Keyboard Shortcuts (spec §8.4). Every command a key can run,
//  by category, with its shortcut. Tap one and press the new keys; Delete
//  removes it, Escape cancels. A shortcut another command had moves here,
//  and the page says which command lost it.
//

import SwiftUI
import UIKit

/// While a shortcut is being recorded, the editor's own key commands stand
/// aside (`CommandShortcutsView`), so the keys reach the recorder.
@MainActor
@Observable
final class ShortcutRecording {
    static let shared = ShortcutRecording()
    var active = false
}

struct KeyboardShortcutsView: View {
    @Bindable var settings: AppSettings
    @State private var recording: String?
    @State private var message: String?
    @State private var query = ""

    private var commands: [AppCommand] {
        _ = settings.shortcuts   // re-read the catalog when it changes
        let all = CommandRegistry.customizableCommands
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            CommandRegistry.score(query: trimmed, title: $0.title) != nil
                || $0.chord?.label.lowercased() == trimmed.lowercased()
        }
    }

    var body: some View {
        let commands = self.commands
        List {
            Section {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("ShortcutMessage")
                }
            } footer: {
                Text("Tap a command, then press its new keys. Delete removes the shortcut; Escape cancels.")
            }
            ForEach(AppCommand.Category.allCases, id: \.self) { category in
                let rows = commands.filter { $0.category == category }
                if !rows.isEmpty {
                    Section(category.title) {
                        ForEach(rows) { row($0) }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Commands")
        .navigationTitle("Keyboard Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reset All") {
                    settings.shortcuts = ShortcutCustomization()
                    recording = nil
                    message = nil
                }
                .disabled(settings.shortcuts.isEmpty)
                .accessibilityIdentifier("ShortcutsResetAll")
            }
        }
        .background(KeyCapture(active: recording != nil, onKey: record))
        .onChange(of: recording) { ShortcutRecording.shared.active = recording != nil }
        .onDisappear { ShortcutRecording.shared.active = false }
    }

    @ViewBuilder
    private func row(_ command: AppCommand) -> some View {
        let shipped = CommandRegistry.defaults.first { $0.id == command.id }?.chord
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                if command.chord != shipped {
                    Text("Default: \(shipped?.label ?? "None")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if recording == command.id {
                Text("Type Shortcut…")
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("ShortcutRecording")
                Button("Cancel") { recording = nil }
                    .buttonStyle(.borderless)
            } else {
                Text(command.chord?.label ?? "—")
                    .font(.body.monospaced())
                    .foregroundStyle(command.chord == nil ? .tertiary : .secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            message = nil
            recording = command.id
        }
        .contextMenu {
            Button("Reset to Default") { reset(command) }
                .disabled(command.chord == shipped)
            Button("Remove Shortcut", role: .destructive) { assign(nil, to: command) }
                .disabled(command.chord == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Shortcut-\(command.id)")
        .accessibilityAddTraits(.isButton)
    }

    private func record(_ press: KeyCapture.Press) {
        guard let id = recording, let command = CommandRegistry.all.first(where: { $0.id == id }) else { return }
        switch press {
        case .cancel:
            recording = nil
        case .clear:
            assign(nil, to: command)
        case .unsupported:
            message = ShortcutCustomization.Refusal.unsupportedKey.message
        case .chord(let chord):
            if let refusal = ShortcutCustomization.refusal(for: chord) {
                message = refusal.message
            } else {
                assign(chord, to: command)
            }
        }
    }

    private func assign(_ chord: KeyChord?, to command: AppCommand) {
        let displaced = settings.shortcuts.assign(chord, to: command.id)
        recording = nil
        message = displaced.map { "\(chord?.label ?? "") was the shortcut for “\($0.title)”, which now has none." }
    }

    private func reset(_ command: AppCommand) {
        let displaced = settings.shortcuts.reset(command.id)
        message = displaced.map { "“\($0.title)” gave up its shortcut to “\(command.title)”." }
    }
}

/// Takes the keyboard while `active` and reports each key press.
struct KeyCapture: UIViewRepresentable {
    enum Press: Equatable {
        case chord(KeyChord)
        case cancel, clear, unsupported
    }

    var active: Bool
    var onKey: (Press) -> Void

    func makeUIView(context: Context) -> CaptureView { CaptureView() }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.onKey = onKey
        view.active = active
        if active, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !active, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    final class CaptureView: UIView {
        var onKey: ((Press) -> Void)?
        var active = false

        override var canBecomeFirstResponder: Bool { active }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard active, let key = presses.first?.key, let press = Self.press(for: key) else {
                super.pressesBegan(presses, with: event)
                return
            }
            onKey?(press)
        }

        /// Nil for a modifier on its own: wait for the key it modifies.
        static func press(for key: UIKey) -> Press? {
            switch key.keyCode {
            case .keyboardLeftShift, .keyboardRightShift, .keyboardLeftGUI, .keyboardRightGUI,
                 .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftControl, .keyboardRightControl,
                 .keyboardCapsLock:
                return nil
            case .keyboardEscape: return .cancel
            case .keyboardDeleteOrBackspace, .keyboardDeleteForward: return .clear
            default: break
            }
            if key.modifierFlags.contains(.control) { return .unsupported }
            var modifiers: KeyChord.Modifiers = []
            if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
            if key.keyCode == .keyboardSpacebar { return .chord(KeyChord("space", modifiers)) }
            // The character the key types, so every layout names its keys as
            // printed; by position only when ⇧ or ⌥ turned a letter or digit
            // into a symbol (⇧1 types "!").
            let typed = key.charactersIgnoringModifiers.lowercased()
            let raw = key.keyCode.rawValue
            let name: String
            if typed.count == 1, typed.first?.isLetter == true || typed.first?.isNumber == true {
                name = typed
            } else if (UIKeyboardHIDUsage.keyboardA.rawValue...UIKeyboardHIDUsage.keyboardZ.rawValue).contains(raw) {
                name = String(UnicodeScalar(UInt8(97 + raw - UIKeyboardHIDUsage.keyboardA.rawValue)))
            } else if (UIKeyboardHIDUsage.keyboard1.rawValue...UIKeyboardHIDUsage.keyboard9.rawValue).contains(raw) {
                name = String(raw - UIKeyboardHIDUsage.keyboard1.rawValue + 1)
            } else if key.keyCode == .keyboard0 {
                name = "0"
            } else {
                name = typed
            }
            guard ShortcutCustomization.assignableKeys.contains(name) else { return .unsupported }
            return .chord(KeyChord(name, modifiers))
        }
    }
}
