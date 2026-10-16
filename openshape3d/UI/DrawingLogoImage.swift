//
//  DrawingLogoImage.swift
//  openshape3d
//
//  A picked picture made ready to be a title block's logo (spec §15): laid
//  on white (the sheet is white paper), at most `DrawingTitleLogo.maxPixels`
//  on a side, as JPEG — which a PDF embeds as it is.
//

import UIKit

enum DrawingLogoImage {
    static func prepare(_ data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let largest = max(pixels.width, pixels.height), limit = CGFloat(DrawingTitleLogo.maxPixels)
        let scale = largest > limit ? limit / largest : 1
        let target = CGSize(width: max(1, (pixels.width * scale).rounded()), height: max(1, (pixels.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
