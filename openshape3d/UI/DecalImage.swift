//
//  DecalImage.swift
//  openshape3d
//
//  A picked picture made ready to be a decal (spec §14): at most
//  `DecalKit.maxPixels` on a side, as PNG (transparency kept), with its
//  height ÷ width.
//

import UIKit

enum DecalImage {
    static func prepare(_ data: Data) -> (image: Data, aspect: Double)? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let largest = max(pixels.width, pixels.height)
        let target = largest > CGFloat(DecalKit.maxPixels)
            ? CGSize(width: pixels.width * CGFloat(DecalKit.maxPixels) / largest,
                     height: pixels.height * CGFloat(DecalKit.maxPixels) / largest)
            : pixels
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let png = UIGraphicsImageRenderer(size: target, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return (png, Double(pixels.height / pixels.width))
    }
}
