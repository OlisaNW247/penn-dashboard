import Foundation
#if canImport(ImageIO)
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Shrinks a picked photo into something a poster idea can carry.
///
/// A phone photo is several megabytes and the ambassador server refuses an
/// idea over 600,000 decoded bytes, so the picture is scaled down and
/// re-encoded before it is sent. The new JPEG is built from the pixels alone:
/// no property dictionary is copied from the source, so the camera's GPS tag,
/// timestamps and device model never leave the phone. (A poster idea does not
/// need to know where it was photographed.) Orientation is baked into the
/// pixels by the thumbnail step, since the EXIF flag that carried it is gone.
///
/// ImageIO and CoreGraphics only, so it builds for macOS (where `swift test`
/// runs) and iOS alike, with no UIKit or AppKit branch. Never upsizes: a small
/// picture keeps its size.
public enum PosterIdeaImage {
    /// JPEG bytes no larger than `maxBytes` and no longer than `maxDimension`
    /// on the long side, or nil when `data` is not an image or cannot be
    /// brought under the limit (quality steps 0.8, 0.65, 0.5, 0.35, then one
    /// halving of the dimension and the same steps again).
    public static func prepared(from data: Data, maxDimension: Int = 1280, maxBytes: Int = 600_000) -> Data? {
        guard !data.isEmpty, maxDimension > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        // ImageIO may scale a thumbnail up to the requested size, so cap the
        // request at the picture's own long side: never upsize.
        var dimension = maxDimension
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int, max(w, h) > 0 {
            dimension = min(dimension, max(w, h))
        }
        for _ in 0..<2 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            if let jpeg = encode(image, maxBytes: maxBytes) { return jpeg }
            dimension = max(1, dimension / 2)
        }
        return nil
    }

    /// The same shrink-and-encode for a picture that is already pixels, such
    /// as a frame read out of a screen recording. The JPEG is built from the
    /// pixels alone, so no metadata can ride along. Scales down with
    /// CoreGraphics when the long side is over `maxDimension` (one halving of
    /// the size and the quality steps again when the bytes will not fit, like
    /// the Data entry point); never upsizes.
    public static func prepared(cgImage: CGImage, maxDimension: Int, maxBytes: Int) -> Data? {
        guard maxDimension > 0 else { return nil }
        var dimension = max(1, min(maxDimension, max(cgImage.width, cgImage.height)))
        for _ in 0..<2 {
            let image = scaled(cgImage, longSide: dimension) ?? cgImage
            if let jpeg = encode(image, maxBytes: maxBytes) { return jpeg }
            dimension = max(1, dimension / 2)
        }
        return nil
    }

    private static func encode(_ image: CGImage, maxBytes: Int) -> Data? {
        for quality in [0.8, 0.65, 0.5, 0.35] {
            if let jpeg = encodeJPEG(image, quality: quality), jpeg.count <= maxBytes { return jpeg }
        }
        return nil
    }

    /// `image` resized so its long side is `longSide`, or nil when it already
    /// is no longer than that (the caller then keeps the original) or a
    /// context cannot be made.
    private static func scaled(_ image: CGImage, longSide: Int) -> CGImage? {
        let long = max(image.width, image.height)
        guard long > longSide, long > 0 else { return nil }
        let ratio = Double(longSide) / Double(long)
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        let type: CFString
        #if canImport(UniformTypeIdentifiers)
        type = UTType.jpeg.identifier as CFString
        #else
        type = "public.jpeg" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        // Only the quality: no source properties, so no metadata survives.
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
#endif
