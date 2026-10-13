//
//  ActivityShareSheet.swift
//  openshape3d
//
//  The system share sheet for files (Export to Slicer on iPad): apps that
//  take the file — a slicer, Files, AirDrop — show up as destinations.
//

import SwiftUI
import UIKit

/// A file waiting in the share sheet.
struct SlicerShare: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
