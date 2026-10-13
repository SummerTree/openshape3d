//
//  SettingsView.swift
//  openshape3d
//
//  App settings sheet (Phase F, spec §17): units, appearance, interface side,
//  anti-aliasing. Bound straight to `AppSettings.shared`; every control
//  persists immediately.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                // First, because the people it is for came for exactly this
                // and know no other setting. Desktop assistants live on the
                // Mac; an iPad has none to pair with (DEBUG keeps the section
                // everywhere so it can be tested).
                #if targetEnvironment(macCatalyst) || DEBUG
                AIAssistantSettingsSection(control: AIControl.shared)
                #endif

                Section("Units") {
                    Picker("Length Unit", selection: $settings.unit) {
                        ForEach(DisplayUnit.allCases, id: \.self) { unit in
                            Text(unit.symbol).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("SettingsUnitPicker")
                    Text("Models are stored in millimetres; this changes how lengths are shown and typed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Sketch Annotations") {
                    Picker("Circular Annotations", selection: $settings.circularAnnotations) {
                        ForEach(CircularAnnotations.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("SettingsCircularAnnotations")
                    Text("Choose radius or diameter readouts for circles without resizing them.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SnappingSettingsSection(settings: settings)

                Section("Appearance") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("SettingsThemePicker")
                }

                Section("Interface") {
                    Picker("Toolbar Side", selection: $settings.paletteOnRight) {
                        Text("Left").tag(false)
                        Text("Right").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("SettingsPaletteSide")
                    Text("Put the tool palette on the right for left-handed sketching.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Single Key Action", selection: $settings.singleKeyAction) {
                        Text("Hotkeys").tag(SingleKeyAction.hotkeys)
                        Text("Command Search").tag(SingleKeyAction.commandSearch)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("SettingsSingleKeyAction")
                    Text("What a single letter does on a hardware keyboard — "
                         + "run its tool, or open Command Search typed with it. "
                         + "⌘ shortcuts work either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Graphics") {
                    Picker("Anti-Aliasing", selection: $settings.antiAliasing) {
                        Text("Off").tag(1)
                        Text("2×").tag(2)
                        Text("4×").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("SettingsAntiAliasing")
                    if settings.antiAliasing != AppSettings.launchSampleCount() {
                        Text("Takes effect the next time the app launches.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Picker("Tessellation Quality", selection: $settings.tessellationQuality) {
                        ForEach(TessellationQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("SettingsTessellation")
                    VStack(alignment: .leading) {
                        LabeledContent("Tool Preview Opacity",
                                       value: "\(Int((settings.toolPreviewOpacity * 100).rounded()))%")
                        Slider(value: $settings.toolPreviewOpacity, in: 0.1...1, step: 0.05)
                            .accessibilityIdentifier("SettingsToolPreviewOpacity")
                        Text("How solid a tool's preview draws while editing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if settings.tessellationQuality != TessellationQuality.launch {
                        Text("Takes effect the next time the app launches, for curved faces built after it.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Picker("Navigation Preset", selection: $settings.navigationPreset) {
                        ForEach(NavigationPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("SettingsNavigationPreset")
                    Toggle("Reverse Scroll Direction", isOn: $settings.reverseZoom)
                        .accessibilityIdentifier("SettingsReverseZoom")
                } header: {
                    Text("Mouse Navigation")
                } footer: {
                    Text(settings.navigationPreset.summary + " The mouse wheel zooms; a trackpad pans with two fingers and pinches to zoom.")
                }

                Section {
                    Toggle("Display Touches and Clicks", isOn: $settings.showTouches)
                        .accessibilityIdentifier("SettingsShowTouches")
                    Toggle("Display Keyboard Shortcuts", isOn: $settings.showKeyPresses)
                        .accessibilityIdentifier("SettingsShowKeys")
                } header: {
                    Text("Tutorial Mode")
                } footer: {
                    Text("For recording tutorials: each touch shows a ring, and each keyboard shortcut its keys.")
                }
            }
            .navigationTitle("Settings")
            .onDisappear { MacWindowTitle.restore() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("SettingsDone")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
