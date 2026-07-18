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
            ProjectGalleryView()
        }
        .modelContainer(sharedModelContainer)
    }
}
