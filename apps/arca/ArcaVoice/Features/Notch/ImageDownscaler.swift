#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Downscales an image on disk to a bounded JPEG for fast, cheap vision calls.
enum ImageDownscaler {
    static func jpeg(from url: URL, maxDimension: CGFloat, quality: CGFloat = 0.7) -> (Data, String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return nil
        }
        return (data, "image/jpeg")
    }
}
#endif
