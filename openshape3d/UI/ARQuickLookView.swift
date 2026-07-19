//
//  ARQuickLookView.swift
//  openshape3d
//
//  AR preview (plan §B14, spec §12): QLPreviewController wrapped for SwiftUI,
//  pointed at a temporary USDZ export. Quick Look supplies the Object/AR
//  toggle on device; the presenting button only exists when
//  USDZExporter.isSupported, so this view never sees an unwritable format.
//

import SwiftUI
import QuickLook

struct ARQuickLookView: UIViewControllerRepresentable {
    /// Temporary .usdz file to preview.
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController, previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
