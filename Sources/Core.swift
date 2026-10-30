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
    let image: CGImage
    let profile: String?   // embedded ICC profile name
    let fileSize: Int?
    var fullSize: CGSize { CGSize(width: image.width, height: image.height) }

    init(url: URL, image: CGImage, profile: String?, fileSize: Int?) {
        self.url = url; self.image = image; self.profile = profile; self.fileSize = fileSize
    }
}

enum Decoder {
    /// Keep decodes within GPU texture limits.
    static let maxLong = 16384

    /// Decodes at full size with EXIF orientation applied and the embedded color profile kept
    /// (Core Animation color-matches it to the display and scales it on the GPU).
    /// A plain full decode is several times faster than ImageIO's downsampling, so we only
    /// downsample images too big for a texture.
    static func decode(_ url: URL) -> Decoded? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = p[kCGImagePropertyOrientation] as? Int ?? 1
        let img: CGImage?
        if orientation == 1, w > 0, max(w, h) <= maxLong {
            img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(max(w, h, 1), maxLong),
            ] as CFDictionary)
        }
        guard let img else { return nil }
        let profile = p[kCGImagePropertyProfileName] as? String
            ?? (img.colorSpace?.name).map { ($0 as String).replacingOccurrences(of: "kCGColorSpace", with: "") }
        let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Decoded(url: url, image: img, profile: profile, fileSize: fileSize)
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
