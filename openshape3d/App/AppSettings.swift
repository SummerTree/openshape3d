//
//  AppSettings.swift
//  openshape3d
//
//  App-wide preferences (Phase F, spec §17): display units, theme, interface
//  side, anti-aliasing. The DOCUMENT always stores millimetres — `DisplayUnit`
//  converts at the view layer only, so switching units never touches geometry.
//

import Foundation
import SwiftUI

// MARK: - Display units

/// User preference for showing/typing lengths. Conversion is view-layer only.
nonisolated enum DisplayUnit: String, CaseIterable, Codable, Sendable {
    case millimeters = "mm"
    case centimeters = "cm"
    case meters = "m"
    case inches = "in"
    case feet = "ft"

    var symbol: String { rawValue }

    /// Multiply a millimetre value by this to get the display value.
    var factorFromMM: Double {
        switch self {
        case .millimeters: return 1
        case .centimeters: return 0.1
        case .meters: return 0.001
        case .inches: return 1 / 25.4
        case .feet: return 1 / 304.8
        }
    }

    /// Sensible decimals for a length readout in this unit.
    var lengthDecimals: Int {
        switch self {
        case .millimeters, .centimeters: return 2
        case .meters, .inches, .feet: return 3
        }
    }

    func display(fromMM value: Double) -> Double { value * factorFromMM }
    func mm(fromDisplay value: Double) -> Double { value / factorFromMM }

    /// "12.70 mm", "0.500 in" — a length readout.
    func lengthString(fromMM value: Double) -> String {
        String(format: "%.\(lengthDecimals)f %@", display(fromMM: value), symbol)
    }

    /// Compact length for labels/pills: trims trailing zeros ("12.7 mm").
    /// Native canvas labels keep every decimal of a dense value and group
    /// thousands — "123,456.7891 mm", "164,058.8074 mm", "R 50,000 mm"
    /// (paired 2026-09-13). `%g` used to cap this at six significant digits,
    /// so the same value read "123457 mm" here.
    func compactLengthString(fromMM value: Double) -> String {
        let v = display(fromMM: value)
        // Native on-canvas imperial dimensions use quote marks rather than
        // the input suffixes shown in the unit picker. Keep those input tokens
        // unchanged, and retain the fourth decimal used by decimal feet.
        let imperial = self == .inches || self == .feet
        // Paired native millimetre input 0.869/2 retains 0.4345 on canvas.
        let decimals = imperial || self == .millimeters ? 4 : 3
        let text = Self.groupedNumber(v, maxFractionDigits: decimals)
        if self == .inches { return text + "\"" }
        if self == .feet { return text + "'" }
        return "\(text) \(symbol)"
    }

    /// "40.00 mm", "1.500\"": exactly `decimals` places (a drawing dimension
    /// set to a precision), grouped like the canvas.
    func fixedLengthString(fromMM value: Double, decimals: Int) -> String {
        let text = Self.groupedNumber(display(fromMM: value), maxFractionDigits: decimals, minFractionDigits: decimals)
        if self == .inches { return text + "\"" }
        if self == .feet { return text + "'" }
        return "\(text) \(symbol)"
    }

    /// Schoolbook rounding to `maxFractionDigits`, trailing zeros trimmed,
    /// thousands grouped with a comma whatever the locale (the canvas is
    /// read against native's, which groups the same way).
    static func groupedNumber(_ value: Double, maxFractionDigits: Int, minFractionDigits: Int = 0) -> String {
        let scale = pow(10.0, Double(maxFractionDigits))
        var rounded = (value * scale).rounded() / scale
        if rounded == 0 { rounded = 0 } // never "-0"
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.maximumFractionDigits = maxFractionDigits
        formatter.minimumFractionDigits = minFractionDigits
        return formatter.string(from: NSNumber(value: rounded)) ?? String(rounded)
    }

    /// "161.29 cm²" — an area readout (factor squared).
    func areaString(fromMM2 value: Double) -> String {
        let f = factorFromMM
        return String(format: "%.\(lengthDecimals)f %@²", value * f * f, symbol)
    }

    /// "16.387 cm³" — a volume readout (factor cubed).
    func volumeString(fromMM3 value: Double) -> String {
        let f = factorFromMM
        return String(format: "%.\(lengthDecimals)f %@³", value * f * f * f, symbol)
    }

    /// A view-layer binding that shows and edits a millimetre value in this
    /// unit (get converts out, set converts back).
    func binding(_ mm: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { self.display(fromMM: mm.wrappedValue) },
            set: { mm.wrappedValue = self.mm(fromDisplay: $0) }
        )
    }
}

/// Settings ▸ Navigation Presets: what a mouse drag with a non-primary
/// button (or a modifier) does, matching the CAD tool the user's hands know.
/// A primary-button drag on empty space orbits in every preset.
nonisolated enum NavigationPreset: String, CaseIterable, Codable, Sendable {
    case shapr3d, solidworks, fusion, onshape

    enum Button: Sendable { case secondary, middle }
    enum Action: String, Sendable { case orbit, pan }

    var title: String {
        switch self {
        case .shapr3d: return "OpenShape3D"
        case .solidworks: return "SOLIDWORKS"
        case .fusion: return "Fusion"
        case .onshape: return "Onshape"
        }
    }

    /// One line for the settings footer.
    var summary: String {
        switch self {
        case .shapr3d: return "Right or middle drag pans."
        case .solidworks: return "Middle drag orbits; Control + middle drag pans."
        case .fusion: return "Middle drag pans; Shift + middle drag orbits."
        case .onshape: return "Right drag orbits; middle drag or Control + right drag pans."
        }
    }

    func action(for button: Button, shift: Bool, control: Bool) -> Action {
        switch (self, button) {
        case (.shapr3d, _): return .pan
        case (.solidworks, .middle): return control ? .pan : .orbit
        case (.solidworks, .secondary): return .pan
        case (.fusion, .middle): return shift ? .orbit : .pan
        case (.fusion, .secondary): return .pan
        case (.onshape, .secondary): return control ? .pan : .orbit
        case (.onshape, .middle): return .pan
        }
    }
}

/// Settings ▸ Tessellation Quality: how finely curved B-rep faces are
/// meshed for display. Read once at launch (face matching tolerances derive
/// from it), so a change applies the next time the app launches.
nonisolated enum TessellationQuality: String, CaseIterable, Codable, Sendable {
    case low, medium, high, veryHigh

    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High (Default)"
        case .veryHigh: return "Very High"
        }
    }

    /// (angular radians, linear mm) for OCCT's incremental mesher.
    var deflection: (angular: Double, linear: Double) {
        switch self {
        case .low: return (0.2, 0.25)
        case .medium: return (0.12, 0.15)
        case .high: return (0.08, 0.1)
        case .veryHigh: return (0.04, 0.05)
        }
    }

    static let defaultsKey = "os3d.tessellationQuality"

    /// The value this launch uses: read once, straight from UserDefaults so
    /// the kernel (nonisolated) can take it without touching AppSettings.
    static let launch: TessellationQuality =
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(TessellationQuality.init) ?? .high
}

/// View ▸ Foot & Inch Format (feet/inch units only).
nonisolated enum FootInchFormat: String, CaseIterable, Codable, Sendable {
    case decimal, architectural
    var title: String {
        self == .architectural ? "Architectural (e.g. 1' - 4 1/2\")" : "Decimal (e.g. 1.375')"
    }
}

/// View ▸ Degree Format.
nonisolated enum DegreeFormat: String, CaseIterable, Codable, Sendable {
    case decimal, fractional
    var title: String {
        self == .fractional ? "Fractional (e.g. 27°15')" : "Decimal (e.g. 27.25°)"
    }

    func string(_ degrees: Double) -> String {
        switch self {
        case .decimal:
            return DisplayUnit.groupedNumber(degrees, maxFractionDigits: 2) + "°"
        case .fractional:
            let sign = degrees < 0 ? "-" : ""
            var whole = floor(abs(degrees))
            var minutes = ((abs(degrees) - whole) * 60).rounded()
            if minutes >= 60 { whole += 1; minutes = 0 }
            return minutes == 0 ? "\(sign)\(Int(whole))°" : "\(sign)\(Int(whole))°\(Int(minutes))'"
        }
    }
}

extension DisplayUnit {
    /// Architectural feet-inch text to the nearest 1/16": 1' - 4 1/2".
    /// Inches unit drops the feet part: 16 1/2".
    nonisolated func architecturalString(fromMM value: Double) -> String {
        let sixteenths = (abs(value) / 25.4 * 16).rounded()
        let sign = value < 0 ? "-" : ""
        var inches = Int(sixteenths) / 16
        var fraction = Int(sixteenths) % 16
        var denominator = 16
        while fraction > 0, fraction % 2 == 0 { fraction /= 2; denominator /= 2 }
        let fractionText = fraction == 0 ? "" : " \(fraction)/\(denominator)"
        if self == .feet {
            let feet = inches / 12
            inches %= 12
            return "\(sign)\(feet)' - \(inches)\(fractionText)\""
        }
        return "\(sign)\(inches)\(fractionText)\""
    }
}

nonisolated enum CircularAnnotations: String, CaseIterable, Codable, Sendable {
    case radiusAndDiameter, alwaysRadius
    var title: String {
        self == .alwaysRadius ? "Always Radius" : "Radius and Diameter"
    }
}

/// Which selected sketch entity stays in place when a new relationship is
/// solved. This is a solve-time preference, not a persisted geometry Lock;
/// existing sketch constraints retain priority.
nonisolated enum AnchoredSketchEntity: String, CaseIterable, Codable, Sendable {
    case firstSelected, lastSelected

    var title: String {
        switch self {
        case .firstSelected: "First Selected"
        case .lastSelected: "Last Selected"
        }
    }
}

/// Settings ▸ Interface ▸ Selection Extension (spec §8.1, Shapr3D's macOS
/// setting): which click adds to the selection.
nonisolated enum SelectionExtension: String, CaseIterable, Codable, Sendable {
    /// A click selects one item; Shift-click adds or removes (default).
    case shiftClick
    /// Every click adds or removes; Shift-click selects just the one item.
    case click

    var title: String {
        switch self {
        case .shiftClick: "Shift-Click Adds"
        case .click: "Click Adds"
        }
    }

    /// Whether a click with Shift held (`shift`) extends the selection.
    func extends(shift: Bool) -> Bool { self == .click ? !shift : shift }
}

/// Settings ▸ General ▸ Start With: what the app shows at launch.
nonisolated enum StartWith: String, CaseIterable, Codable, Sendable {
    case gallery, lastDesign, newDesign

    var title: String {
        switch self {
        case .gallery: "Designs Gallery"
        case .lastDesign: "Last Opened Design"
        case .newDesign: "New Design"
        }
    }

    enum Launch: Equatable { case stay, open, create }

    /// What to do at launch. The welcome screen (first run) and automation
    /// hooks win; a missing last design falls back to the gallery.
    func launch(hasLastDesign: Bool, welcomeShowing: Bool, hookActive: Bool) -> Launch {
        guard !welcomeShowing, !hookActive else { return .stay }
        switch self {
        case .gallery: return .stay
        case .lastDesign: return hasLastDesign ? .open : .stay
        case .newDesign: return .create
        }
    }
}

// MARK: - Theme

nonisolated enum AppTheme: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    var title: String { rawValue.capitalized }

    /// nil = follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Settings store

/// Singleton preference store, UserDefaults-backed. Views read it through
/// `@Observable` tracking so a change re-renders everything that shows units,
/// flips the palette, or re-themes the window.
@Observable
final class AppSettings {
    /// Numeric fields on a desktop start with the real keyboard, focused,
    /// and never raise the on-screen keypad: on the Mac (Catalyst) a click
    /// on the extrude distance opened the ten-key and typed digits went
    /// nowhere (Release smoke test, 2026-09-14). iPad keeps the keypad, with
    /// its keyboard key handing over to the system keyboard.
    nonisolated static let prefersSystemKeyboard: Bool = {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }()

    static let shared: AppSettings = {
        let settings = AppSettings()
        CommandRegistry.customization = settings.shortcuts
        return settings
    }()

    private enum Key {
        static let unit = "os3d.displayUnit"
        static let circularAnnotations = "os3d.circularAnnotations"
        static let theme = "os3d.theme"
        static let paletteOnRight = "os3d.paletteOnRight"
        static let antiAliasing = "os3d.antiAliasing"
        static let singleKeyAction = "os3d.singleKeyAction"
        static let alwaysShowDimensions = "os3d.alwaysShowDimensions"
        static let alwaysShowConstraints = "os3d.alwaysShowConstraints"
        static let anchoredSketchEntity = "os3d.anchoredSketchEntity"
        static let snapToGrid = "os3d.snapToGrid"
        static let snapToSketchGuidelines = "os3d.snapToSketchGuidelines"
        static let snapToSketchGuidepoints = "os3d.snapToSketchGuidepoints"
        static let snapToFaceGuidepoints = "os3d.snapToFaceGuidepoints"
        static let snapToDistantEdges = "os3d.snapToDistantEdges"
        static let toolPreviewOpacity = "os3d.toolPreviewOpacity"
        static let showSnapHints = "os3d.showSnapHints"
        static let hasSeenWelcome = "os3d.hasSeenWelcome"
        static let footInchFormat = "os3d.footInchFormat"
        static let degreeFormat = "os3d.degreeFormat"
        static let reverseZoom = "os3d.reverseZoom"
        static let navigationPreset = "os3d.navigationPreset"
        static let showTouches = "os3d.tutorialShowTouches"
        static let showKeyPresses = "os3d.tutorialShowKeyPresses"
        static let selectionExtension = "os3d.selectionExtension"
        static let menuButtonLabels = "os3d.menuButtonLabels"
        static let startWith = "os3d.startWith"
        static let lastOpenedDesign = "os3d.lastOpenedDesign"
        static let defaultSplineType = "os3d.defaultSplineType"
        static let spaceMouse = "os3d.spaceMouse"
        static let shortcuts = "os3d.keyboardShortcuts"
    }

    /// Settings ▸ Keyboard Shortcuts: the changes from the default keys.
    /// The app's own settings (not a test's) drive the live catalog.
    var shortcuts: ShortcutCustomization {
        didSet {
            defaults.set(try? JSONEncoder().encode(shortcuts), forKey: Key.shortcuts)
            if self === AppSettings.shared { CommandRegistry.customization = shortcuts }
        }
    }

    /// Settings ▸ SpaceMouse (spec §7.5), stored as one JSON value.
    var spaceMouse: SpaceMouseSettings {
        didSet { defaults.set(try? JSONEncoder().encode(spaceMouse), forKey: Key.spaceMouse) }
    }

    /// Interface ▸ Selection Extension.
    var selectionExtension: SelectionExtension {
        didSet { defaults.set(selectionExtension.rawValue, forKey: Key.selectionExtension) }
    }
    /// Interface ▸ Menu Button Labels: names under the toolbar's icons.
    var menuButtonLabels: Bool {
        didSet { defaults.set(menuButtonLabels, forKey: Key.menuButtonLabels) }
    }
    /// General ▸ Start With.
    var startWith: StartWith {
        didSet { defaults.set(startWith.rawValue, forKey: Key.startWith) }
    }
    /// The design opened most recently (a project's creation date, which is
    /// stable and unique enough to find it again), for Start With ▸ Last
    /// Opened Design.
    var lastOpenedDesign: Date? {
        didSet { defaults.set(lastOpenedDesign, forKey: Key.lastOpenedDesign) }
    }
    /// Sketching ▸ Default Spline Type: what the Spline tool starts in.
    var defaultSplineType: SplineType {
        didSet { defaults.set(defaultSplineType.rawValue, forKey: Key.defaultSplineType) }
    }

    /// The welcome screen has been dismissed once. Stored as soon as it is
    /// shown, so an app killed mid-welcome does not nag on the next launch.
    var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: Key.hasSeenWelcome) }
    }

    var circularAnnotations: CircularAnnotations {
        didSet { defaults.set(circularAnnotations.rawValue, forKey: Key.circularAnnotations) }
    }
    var unit: DisplayUnit {
        didSet { defaults.set(unit.rawValue, forKey: Key.unit) }
    }
    /// View ▸ Foot & Inch Format; only read for feet and inches.
    var footInchFormat: FootInchFormat {
        didSet { defaults.set(footInchFormat.rawValue, forKey: Key.footInchFormat) }
    }
    /// View ▸ Degree Format.
    var degreeFormat: DegreeFormat {
        didSet { defaults.set(degreeFormat.rawValue, forKey: Key.degreeFormat) }
    }
    /// Settings ▸ Zoom: Reverse scroll direction (mouse wheel).
    var reverseZoom: Bool {
        didSet { defaults.set(reverseZoom, forKey: Key.reverseZoom) }
    }
    /// Settings ▸ View Navigation: Navigation Presets.
    var navigationPreset: NavigationPreset {
        didSet { defaults.set(navigationPreset.rawValue, forKey: Key.navigationPreset) }
    }
    /// Settings ▸ Tessellation Quality; applies at the next launch.
    /// Display Modes ▸ Tool Preview Opacity: how solid a tool's preview
    /// body draws while editing (0.1…1).
    var toolPreviewOpacity: Double {
        didSet { defaults.set(toolPreviewOpacity, forKey: Key.toolPreviewOpacity) }
    }
    static let defaultToolPreviewOpacity = 0.55

    var tessellationQuality: TessellationQuality {
        didSet { defaults.set(tessellationQuality.rawValue, forKey: TessellationQuality.defaultsKey) }
    }
    /// Settings ▸ Tutorial Mode: show touches / clicks, and key presses.
    var showTouches: Bool {
        didSet { defaults.set(showTouches, forKey: Key.showTouches) }
    }
    var showKeyPresses: Bool {
        didSet { defaults.set(showKeyPresses, forKey: Key.showKeyPresses) }
    }
    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }
    /// Shapr3D's "interface side": tool palette on the right for left-handed
    /// use (panels stay put; only the palette flips).
    var paletteOnRight: Bool {
        didSet { defaults.set(paletteOnRight, forKey: Key.paletteOnRight) }
    }
    /// MSAA sample count (1 = off, 2, 4). Pipelines bake the sample count at
    /// startup, so this takes effect on the next launch (the sheet says so).
    var antiAliasing: Int {
        didSet { defaults.set(antiAliasing, forKey: Key.antiAliasing) }
    }
    /// What a BARE letter does on a hardware keyboard (spec §8.4): fire the
    /// hotkey it is bound to, or open Command Search pre-typed with it.
    /// Chorded shortcuts (⌘Z, ⇧⌘I…) are unaffected either way.
    var singleKeyAction: SingleKeyAction {
        didSet { defaults.set(singleKeyAction.rawValue, forKey: Key.singleKeyAction) }
    }

    /// Shapr3D's "Constraint & Locked Dimension Visibility": when on, a
    /// sketch's dimensions stay on canvas after you leave the sketch, and every
    /// visible sketch shows its own — not just the one being edited. Off, they
    /// follow the selection, which is Shapr3D's shipped default.
    var alwaysShowDimensions: Bool {
        didSet { defaults.set(alwaysShowDimensions, forKey: Key.alwaysShowDimensions) }
    }
    /// The same, for constraint glyphs.
    var alwaysShowConstraints: Bool {
        didSet { defaults.set(alwaysShowConstraints, forKey: Key.alwaysShowConstraints) }
    }
    var anchoredSketchEntity: AnchoredSketchEntity {
        didSet { defaults.set(anchoredSketchEntity.rawValue, forKey: Key.anchoredSketchEntity) }
    }

    var snapToGrid: Bool {
        didSet { defaults.set(snapToGrid, forKey: Key.snapToGrid) }
    }
    var snapToSketchGuidelines: Bool {
        didSet { defaults.set(snapToSketchGuidelines, forKey: Key.snapToSketchGuidelines) }
    }
    var snapToSketchGuidepoints: Bool {
        didSet { defaults.set(snapToSketchGuidepoints, forKey: Key.snapToSketchGuidepoints) }
    }
    var snapToFaceGuidepoints: Bool {
        didSet { defaults.set(snapToFaceGuidepoints, forKey: Key.snapToFaceGuidepoints) }
    }
    var snapToDistantEdges: Bool {
        didSet { defaults.set(snapToDistantEdges, forKey: Key.snapToDistantEdges) }
    }
    var showSnapHints: Bool {
        didSet { defaults.set(showSnapHints, forKey: Key.showSnapHints) }
    }

    var snapOptions: SnapOptions {
        SnapOptions(grid: snapToGrid, sketchGuidepoints: snapToSketchGuidepoints,
                    faceGuidepoints: snapToFaceGuidepoints, distantEdges: snapToDistantEdges)
    }

    /// The sample count pipelines were actually built with this launch.
    static func launchSampleCount(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: Key.antiAliasing)
        return [1, 2, 4].contains(stored) ? stored : 4
    }

    /// A stored Bool, or nil when the key was never set. Launch arguments
    /// (`-os3d.snapToGrid NO`, the UI tests' override route) reach the
    /// argument domain as strings, which `object(forKey:) as? Bool` would
    /// silently drop back to the default — read those the way `bool(forKey:)`
    /// does. Unlike `bool(forKey:)`, unset stays distinguishable from false.
    private static func storedBool(_ defaults: UserDefaults, _ key: String) -> Bool? {
        switch defaults.object(forKey: key) {
        case let number as NSNumber: return number.boolValue
        case let text as NSString: return text.boolValue
        default: return nil
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        circularAnnotations = defaults.string(forKey: Key.circularAnnotations)
            .flatMap(CircularAnnotations.init) ?? .radiusAndDiameter
        snapToGrid = Self.storedBool(defaults, Key.snapToGrid) ?? true
        snapToSketchGuidelines = Self.storedBool(defaults, Key.snapToSketchGuidelines) ?? true
        snapToSketchGuidepoints = Self.storedBool(defaults, Key.snapToSketchGuidepoints) ?? true
        snapToFaceGuidepoints = Self.storedBool(defaults, Key.snapToFaceGuidepoints) ?? true
        snapToDistantEdges = Self.storedBool(defaults, Key.snapToDistantEdges) ?? true
        showSnapHints = Self.storedBool(defaults, Key.showSnapHints) ?? true
        hasSeenWelcome = Self.storedBool(defaults, Key.hasSeenWelcome) ?? false
        unit = defaults.string(forKey: Key.unit).flatMap(DisplayUnit.init) ?? .millimeters
        footInchFormat = defaults.string(forKey: Key.footInchFormat).flatMap(FootInchFormat.init) ?? .decimal
        degreeFormat = defaults.string(forKey: Key.degreeFormat).flatMap(DegreeFormat.init) ?? .decimal
        reverseZoom = Self.storedBool(defaults, Key.reverseZoom) ?? false
        navigationPreset = defaults.string(forKey: Key.navigationPreset).flatMap(NavigationPreset.init) ?? .shapr3d
        toolPreviewOpacity = (defaults.object(forKey: Key.toolPreviewOpacity) as? Double)
            .map { min(max($0, 0.1), 1) } ?? Self.defaultToolPreviewOpacity
        tessellationQuality = defaults.string(forKey: TessellationQuality.defaultsKey)
            .flatMap(TessellationQuality.init) ?? .high
        showTouches = Self.storedBool(defaults, Key.showTouches) ?? false
        showKeyPresses = Self.storedBool(defaults, Key.showKeyPresses) ?? false
        theme = defaults.string(forKey: Key.theme).flatMap(AppTheme.init) ?? .system
        paletteOnRight = defaults.bool(forKey: Key.paletteOnRight)
        antiAliasing = Self.launchSampleCount(defaults: defaults)
        singleKeyAction = defaults.string(forKey: Key.singleKeyAction)
            .flatMap(SingleKeyAction.init) ?? .hotkeys
        // Both default OFF, verified against the running Shapr3D: its
        // Constraint Settings ship "Always Show Constraints" and "Always Show
        // Dimensions" off, with the footer "Logical constraints and locked
        // dimensions are shown based on your current selection." Off is NOT
        // hidden here either — individual annotations follow selected geometry.
        // `object(forKey:)` so an explicit choice survives a
        // relaunch (`bool(forKey:)` cannot tell false from unset).
        alwaysShowDimensions =
            defaults.object(forKey: Key.alwaysShowDimensions) as? Bool ?? false
        // Constraints default OFF: a canvas of ⌖ ∥ ⊥ ◎ badges over every visible
        // sketch while you are modelling is noise, and Shapr3D does not do it by
        // default either. Off still shows annotations referring to selected geometry.
        alwaysShowConstraints =
            defaults.object(forKey: Key.alwaysShowConstraints) as? Bool ?? false
        anchoredSketchEntity = defaults.string(forKey: Key.anchoredSketchEntity)
            .flatMap(AnchoredSketchEntity.init) ?? .firstSelected
        selectionExtension = defaults.string(forKey: Key.selectionExtension)
            .flatMap(SelectionExtension.init) ?? .shiftClick
        menuButtonLabels = Self.storedBool(defaults, Key.menuButtonLabels) ?? false
        startWith = defaults.string(forKey: Key.startWith).flatMap(StartWith.init) ?? .gallery
        lastOpenedDesign = defaults.object(forKey: Key.lastOpenedDesign) as? Date
        defaultSplineType = defaults.string(forKey: Key.defaultSplineType).flatMap(SplineType.init) ?? .fit
        shortcuts = defaults.data(forKey: Key.shortcuts)
            .flatMap { try? JSONDecoder().decode(ShortcutCustomization.self, from: $0) } ?? ShortcutCustomization()
        spaceMouse = defaults.data(forKey: Key.spaceMouse)
            .flatMap { try? JSONDecoder().decode(SpaceMouseSettings.self, from: $0) } ?? SpaceMouseSettings()
    }

    // Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, this class is
    // implicitly `@MainActor`, and (SE-0371) a global-actor-isolated `deinit`
    // is isolated to that actor. Deallocating an isolated-`deinit` `@Observable`
    // then routes through `swift_task_deinitOnExecutorImpl`, which double-frees
    // in the current toolchain — deterministically crashing any test that lets
    // an `AppSettings` instance go out of scope (malloc "pointer being freed
    // was not allocated"). There's no teardown work to do here, so opt the
    // deinit out of actor isolation to skip the executor hop entirely.
    nonisolated deinit {}
}
