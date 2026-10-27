import Foundation
import AppKit
import ImageIO
import AVFoundation

/// Reading pixels and metadata from photo and video files.
enum MediaReader {
    /// Decodes an image scaled so that its longest side is at most `maxPixel`, with EXIF orientation applied.
    static func thumbnail(path: String, maxPixel: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url, sourceOptions) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// A deterministic frame of a video (about one second in), used both for analysis and posters.
    static func videoFrame(path: String, maxPixel: Int) -> CGImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let duration = CMTimeGetSeconds(asset.duration)
        let seconds = (duration.isFinite && duration > 0) ? min(1.0, duration / 2) : 0
        return try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }

    /// The image used for recognition. Face rectangles are stored relative to it.
    static func analysisImage(path: String, kind: Int, maxPixel: Int = 1024) -> CGImage? {
        kind == 1 ? videoFrame(path: path, maxPixel: maxPixel) : thumbnail(path: path, maxPixel: maxPixel)
    }

    static func downscale(_ cg: CGImage, maxPixel: Int) -> CGImage? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, Double(maxPixel) / Double(max(w, h)))
        let nw = max(1, Int(Double(w) * scale))
        let nh = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }

    /// Square crop around a face. `rect` is normalized with a top-left origin.
    static func faceCrop(_ cg: CGImage, rect: CGRect, scale: CGFloat) -> CGImage? {
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let fw = rect.width * W, fh = rect.height * H
        guard fw >= 8, fh >= 8 else { return nil }
        let side = min(max(fw, fh) * scale, min(W, H))
        var x = rect.midX * W - side / 2
        var y = rect.midY * H - side / 2 - side * 0.04
        x = max(0, min(x, W - side))
        y = max(0, min(y, H - side))
        return cg.cropping(to: CGRect(x: x, y: y, width: side, height: side).integral)
    }

    // MARK: Dates

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static func plausible(_ d: Date) -> Bool {
        d.timeIntervalSince1970 > 31_536_000 && d < Date().addingTimeInterval(2 * 86_400)
    }

    static func captureDate(path: String, kind: Int) -> Date? {
        let url = URL(fileURLWithPath: path)
        if kind == 1 {
            let asset = AVURLAsset(url: url)
            if let d = asset.creationDate?.dateValue, plausible(d) { return d }
            return nil
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let raw = (exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime as String] as? String)
        guard let string = raw, let d = exifFormatter.date(from: string), plausible(d) else { return nil }
        return d
    }
}

// MARK: - Image cache for the UI

final class ImageStore {
    static let shared = ImageStore()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 700
    }

    static func image(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func thumb(_ item: MediaItem, maxPixel: Int = 420) async -> NSImage? {
        let key = "t\(maxPixel)-\(item.id)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let cg = item.isVideo
                ? MediaReader.videoFrame(path: item.path, maxPixel: maxPixel)
                : MediaReader.thumbnail(path: item.path, maxPixel: maxPixel)
            return cg.map { ImageStore.image($0) }
        }.value
        if let image = image { cache.setObject(image, forKey: key) }
        return image
    }

    func display(_ item: MediaItem) async -> NSImage? {
        let maxPixel = SlideshowModel.screenPixels()
        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let cg = item.isVideo
                ? MediaReader.videoFrame(path: item.path, maxPixel: 1600)
                : MediaReader.thumbnail(path: item.path, maxPixel: maxPixel)
            return cg.map { ImageStore.image($0) }
        }.value
    }

    func face(_ face: FaceRef) async -> NSImage? {
        let key = "f\(face.id)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let file = AppPaths.faceCache.appendingPathComponent("\(face.id).jpg")
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            if let data = try? Data(contentsOf: file), let img = NSImage(data: data) { return img }
            let source = face.kind == 1
                ? MediaReader.videoFrame(path: face.path, maxPixel: 1280)
                : MediaReader.thumbnail(path: face.path, maxPixel: 1600)
            guard let cg = source, let crop = MediaReader.faceCrop(cg, rect: face.rect, scale: 1.8) else { return nil }
            let small = MediaReader.downscale(crop, maxPixel: 320) ?? crop
            let rep = NSBitmapImageRep(cgImage: small)
            if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                try? jpg.write(to: file)
            }
            return ImageStore.image(small)
        }.value
        if let image = image { cache.setObject(image, forKey: key) }
        return image
    }

    static func loadSlide(_ item: MediaItem, maxPixel: Int) -> SlidePayload {
        let source = item.isVideo
            ? MediaReader.videoFrame(path: item.path, maxPixel: 1600)
            : MediaReader.thumbnail(path: item.path, maxPixel: maxPixel)
        guard let cg = source else { return SlidePayload(image: nil, backdrop: nil, names: []) }
        let backdrop = MediaReader.downscale(cg, maxPixel: 36).map { image($0) }
        return SlidePayload(image: image(cg), backdrop: backdrop, names: Library.names(inPhoto: item.id))
    }
}
