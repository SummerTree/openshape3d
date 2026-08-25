//
//  openshape3dApp.swift
//  openshape3d
//

import SwiftUI
import SwiftData

@main
struct openshape3dApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Project.self,
            PersistedBody.self,
            PersistedSketch.self,
            PersistedPlane.self,
            PersistedImage.self,
            PersistedSymbol.self,
            PersistedFeature.self,
            PersistedVariable.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .macWindowSizing()
        }
        .modelContainer(sharedModelContainer)
    }
}

private extension View {
    /// Mac Catalyst: give the window a sensible floor and opening size.
    ///
    /// A Catalyst window is freely resizable, and this is a CAD app — squeezed
    /// below iPhone width the bottom bars collapse into their stacked compact
    /// layout and the tool palette starts scrolling, which on a desktop reads
    /// as breakage rather than adaptation. The floor is just above the compact
    /// breakpoint so the regular-width layout always holds.
    @ViewBuilder
    func macWindowSizing() -> some View {
        #if targetEnvironment(macCatalyst)
        onAppear {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene,
                      let restrictions = windowScene.sizeRestrictions
                else { continue }
                // Floor only — `maximumSize` is left at its default so the
                // window can still be zoomed to fill a large display.
                restrictions.minimumSize = CGSize(width: 900, height: 620)
            }
        }
        #else
        self
        #endif
    }
}

/// Applies the user's theme preference app-wide; a separate view so the
/// `@Observable` settings read is tracked and re-themes live.
private struct ThemedRoot: View {
    private var settings = AppSettings.shared

    var body: some View {
        ProjectGalleryView()
            .preferredColorScheme(settings.theme.colorScheme)
    }
}
