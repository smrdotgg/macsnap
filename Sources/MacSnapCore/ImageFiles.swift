import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFiles {
    /// PNG bytes carrying DPI = 72 × scale, so Preview, Finder and Quick Look
    /// (and MacSnap itself) show the image at its logical size.
    public static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * max(1, scale)
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    public static func writePNG(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        guard let data = pngData(image, scale: scale) else {
            throw NSError(domain: "MacSnap", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public struct Loaded {
        public var image: CGImage
        public var scale: CGFloat
        public init(image: CGImage, scale: CGFloat) { self.image = image; self.scale = scale }
    }

    /// Decodes an image; the display scale comes from DPI when it looks like a
    /// screenshot (an integer-ish multiple of 72 between 1× and 4×).
    public static func load(data: Data) -> Loaded? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return load(source: src)
    }

    public static func load(url: URL) -> Loaded? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return load(source: src)
    }

    static func load(source src: CGImageSource) -> Loaded? {
        guard CGImageSourceGetCount(src) > 0,
              let raw = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        var scale: CGFloat = 1
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let dpi = props[kCGImagePropertyDPIWidth] as? Double {
            let s = dpi / 72
            if s >= 1, s <= 4, abs(s - s.rounded()) < 0.01 || abs(s * 2 - (s * 2).rounded()) < 0.01 { scale = s }
        }
        return Loaded(image: normalized(raw) ?? raw, scale: scale)
    }

    /// Converts to 8-bit premultiplied sRGB so every later step sees one format.
    public static func normalized(_ img: CGImage) -> CGImage? {
        guard let ctx = CaptureRenderer.makeContext(width: img.width, height: img.height) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    public static func thumbnail(_ img: CGImage, maxPixel: Int) -> CGImage? {
        let k = min(1, CGFloat(maxPixel) / CGFloat(max(img.width, img.height)))
        let w = max(1, Int(CGFloat(img.width) * k)), h = max(1, Int(CGFloat(img.height) * k))
        guard let ctx = CaptureRenderer.makeContext(width: w, height: h) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
