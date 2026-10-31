import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Zoom modes

enum ZoomMode: Int, CaseIterable {
    case realSize = 1, fitAll, fitSmaller, fitLarger

    var title: String {
        switch self {
        case .realSize: return "100 % (actual size)"
        case .fitAll: return "Fit all"
        case .fitSmaller: return "Fit smaller only"
        case .fitLarger: return "Fit larger only"
        }
    }

    static var saved: ZoomMode {
        get { ZoomMode(rawValue: UserDefaults.standard.integer(forKey: "zoomMode")) ?? .fitAll }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "zoomMode") }
    }
}

/// How an image of a given (oriented) pixel size is laid out on the available screen area.
struct Layout: Equatable {
    var mode: ZoomMode
    var areaPx: CGSize   // available area in physical pixels

    /// Image pixels -> screen pixels.
    func baseScale(_ s: CGSize) -> CGFloat {
        guard s.width > 0, s.height > 0, areaPx.width > 0, areaPx.height > 0 else { return 1 }
        let fit = min(areaPx.width / s.width, areaPx.height / s.height)
        switch mode {
        case .realSize: return 1
        case .fitAll: return fit
        case .fitSmaller: return max(fit, 1)
        case .fitLarger: return min(fit, 1)
        }
    }
}

// MARK: - Decoding

final class Decoded {
    let url: URL
    let image: CGImage     // stored pixels; `orientation` says how to turn them upright
    let orientation: Int   // EXIF orientation still to apply when displaying (1 = upright)
    let fullSize: CGSize   // upright pixel size of the original
    let profile: String?   // embedded ICC profile name
    let fileSize: Int?

    init(url: URL, image: CGImage, orientation: Int, fullSize: CGSize, profile: String?, fileSize: Int?) {
        self.url = url; self.image = image; self.orientation = orientation; self.fullSize = fullSize
        self.profile = profile; self.fileSize = fileSize
    }

    /// Turns the stored pixels upright, about the layer's center.
    var transform: CGAffineTransform { Decoder.uprightTransform(orientation) }
}

enum Decoder {
    /// Keep decodes within GPU texture limits.
    static let maxLong = 16384

    /// Leaves the decode to Core Animation: an image from ImageIO is decoded when the layer first
    /// shows it, with the hardware JPEG decoder, faster than any decode on the CPU here. EXIF rotation
    /// is a layer transform for the same reason, and CA color-matches the embedded profile.
    /// Images over the texture limit are decoded at half size (JPEG/HEIC/PNG/TIFF do that
    /// natively) and redrawn upright on this background thread.
    static func decode(_ url: URL) -> Decoded? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        var orientation = min(max(p[kCGImagePropertyOrientation] as? Int ?? 1, 1), 8)
        let upright = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        var img: CGImage?
        if w > 0, max(w, h) <= maxLong {
            img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else if w > 0, let half = CGImageSourceCreateImageAtIndex(src, 0, [
            kCGImageSourceSubsampleFactor: 2, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
            max(half.width, half.height) <= maxLong, let r = render(half, orientation: orientation) {
            img = r
            orientation = 1
        }
        if img == nil {
            // No size info, or a format that can't subsample: let ImageIO scale and rotate.
            img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(max(w, h, 1), maxLong),
            ] as CFDictionary)
            orientation = 1
        }
        guard let img else { return nil }
        let profile = p[kCGImagePropertyProfileName] as? String
            ?? (img.colorSpace?.name).map { ($0 as String).replacingOccurrences(of: "kCGColorSpace", with: "") }
        let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Decoded(url: url, image: img, orientation: orientation,
                       fullSize: w > 0 ? upright : CGSize(width: img.width, height: img.height),
                       profile: profile, fileSize: fileSize)
    }

    /// EXIF orientation as a rotation/mirror of the stored pixels (y up, about the center).
    static func uprightTransform(_ orientation: Int) -> CGAffineTransform {
        let angle: CGFloat
        switch orientation {
        case 3, 4: angle = .pi
        case 5, 8: angle = .pi / 2
        case 6, 7: angle = -.pi / 2
        default: angle = 0
        }
        let mirrored = [2, 4, 5, 7].contains(orientation)
        return CGAffineTransform(rotationAngle: angle).scaledBy(x: mirrored ? -1 : 1, y: 1)
    }

    /// The part of the image shown on screen, as shown: `visible` is in the original's upright pixels,
    /// `scale` is screen pixels per original pixel. Transparency comes out on black, like the window.
    static func view(_ d: Decoded, visible v: CGRect, scale s: CGFloat) -> CGImage? {
        let w = max(1, Int((v.width * s).rounded())), h = max(1, Int((v.height * s).rounded()))
        var cs = d.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if cs.model != .rgb || !cs.supportsOutput { cs = CGColorSpace(name: CGColorSpace.displayP3)! }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = s >= 3 ? .none : .high   // same filtering as the layer
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: d.fullSize.width / 2 - v.minX, y: d.fullSize.height / 2 - v.minY)
        ctx.concatenate(d.transform)
        // Stored pixels in the original's units (a half-size decode is drawn at full size).
        let sw = d.orientation >= 5 ? d.fullSize.height : d.fullSize.width
        let sh = d.orientation >= 5 ? d.fullSize.width : d.fullSize.height
        ctx.draw(d.image, in: CGRect(x: -sw / 2, y: -sh / 2, width: sw, height: sh))
        return ctx.makeImage()
    }

    /// PNG (CleanShot doesn't open TIFF); skipping PNG's row filters makes it ~15 % faster to write.
    /// `dpi` 144 marks a Retina image, so apps show it at 100 % as big as it was on screen.
    static func writePNG(_ img: CGImage, to url: URL, dpi: CGFloat = 72) -> Bool {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                      kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: 0x08]]
        CGImageDestinationAddImage(dst, img, props as CFDictionary)
        return CGImageDestinationFinalize(dst)
    }

    /// Draws 8-bit pixels 1:1 and upright into a native-format bitmap in the image's own color
    /// space, so nothing is left to decode or convert on the main thread. Nil for deeper pixels.
    static func render(_ img: CGImage, orientation: Int) -> CGImage? {
        guard img.bitsPerComponent <= 8 else { return nil }
        let swap = orientation >= 5
        let w = swap ? img.height : img.width, h = swap ? img.width : img.height
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(img.alphaInfo)
        var cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx: CGContext?
        if cs.model == .monochrome, !alpha {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else {
            if cs.model != .rgb || !cs.supportsOutput { cs = CGColorSpace(name: CGColorSpace.displayP3)! }
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedFirst : .noneSkipFirst).rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard let ctx else { return nil }
        ctx.interpolationQuality = .none
        // Rotate/mirror about the center, then draw the stored pixels centered.
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.concatenate(uprightTransform(orientation))
        ctx.draw(img, in: CGRect(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2,
                                 width: CGFloat(img.width), height: CGFloat(img.height)))
        return ctx.makeImage()
    }
}

// MARK: - Background loading + cache

final class Loader {
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()
    private var cache: [URL: Decoded] = [:]
    private var inflight: [URL: Operation] = [:]
    var onLoad: ((Decoded) -> Void)?

    func cached(_ url: URL) -> Decoded? { cache[url] }

    func request(_ url: URL, priority: Operation.QueuePriority = .normal) {
        if cache[url] != nil { return }
        if let op = inflight[url] {
            if priority.rawValue > op.queuePriority.rawValue { op.queuePriority = priority }
            return
        }
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let op, !op.isCancelled else { return }
            Debug.mark("decode start \(url.lastPathComponent)")
            let d = Decoder.decode(url)
            Debug.mark("decode end \(url.lastPathComponent)")
            DispatchQueue.main.async {
                guard let self, self.inflight[url] === op else { return }
                self.inflight[url] = nil
                guard let d else { return }
                self.cache[url] = d
                self.onLoad?(d)
            }
        }
        op.queuePriority = priority
        inflight[url] = op
        queue.addOperation(op)
    }

    /// Drop everything not in `keep`.
    func retain(_ keep: Set<URL>) {
        for (u, op) in inflight where !keep.contains(u) { op.cancel(); inflight[u] = nil }
        for u in cache.keys where !keep.contains(u) { cache[u] = nil }
    }
}

// MARK: - Folder listing

enum ImageList {
    static let extensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "heic", "heif", "avif", "webp", "tif", "tiff", "bmp",
        "psd", "jxl", "jp2", "ico", "icns", "tga", "exr", "hdr",
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq", "erf", "mos", "rwl",
    ]

    static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
    }

    /// Images in the folder, in Finder's name order.
    static func images(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter(isImage).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}
