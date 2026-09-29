import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct EncodedImage: Sendable, Equatable {
    public let data: Data
    public let mimeType: String
    public let width: Int
    public let height: Int
}

/// Screenshots for agents are scaled so the long edge is at most this many pixels. Tool
/// coordinates are pixels of that image, so they stay the same across calls.
public enum ScreenGeometry {
    public static let screenshotLongEdge = 1280

    public static func screenshotSize(forFrameWidth width: Int, height: Int, longEdge: Int = screenshotLongEdge)
        -> (width: Int, height: Int)
    {
        let longest = max(width, height)
        guard longest > longEdge, longest > 0 else { return (width, height) }
        let scale = Double(longEdge) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
}

public enum ImageTools {
    public static func scaled(_ image: CGImage, longEdge: Int?) -> CGImage {
        guard let longEdge else { return image }
        let size = ScreenGeometry.screenshotSize(forFrameWidth: image.width, height: image.height, longEdge: longEdge)
        guard size.width != image.width || size.height != image.height else { return image }
        guard
            let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage() ?? image
    }

    public static func encode(_ image: CGImage, png: Bool = false, quality: Double = 0.75) -> EncodedImage? {
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let options = png ? [:] as CFDictionary : [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return EncodedImage(
            data: data as Data, mimeType: png ? "image/png" : "image/jpeg", width: image.width, height: image.height)
    }

    /// The agent-facing screenshot: scaled to `ScreenGeometry.screenshotLongEdge`, JPEG.
    public static func screenshot(_ frame: CGImage) -> EncodedImage? {
        encode(scaled(frame, longEdge: ScreenGeometry.screenshotLongEdge))
    }
}
