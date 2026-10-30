import AppKit

/// Testing aid: with KUK_SNAPSHOT=/path.png set, renders the view's layers to a PNG
/// shortly after the first image appears and prints the time since process start.
enum Debug {
    static var snapshotPath: String? { ProcessInfo.processInfo.environment["KUK_SNAPSHOT"] }

    static let enabled = snapshotPath != nil

    static func mark(_ label: String) {
        guard enabled else { return }
        FileHandle.standardError.write("\(sinceLaunchMs()) ms  [\(String(format: "%.3f", Date().timeIntervalSince1970))]  \(label)\n".data(using: .utf8)!)
    }

    static func sinceLaunchMs() -> Int {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return Int((Date().timeIntervalSince1970 - started) * 1000)
    }

    /// KUK_KEYS="h,f,space" — keys sent to the view before the snapshot.
    static func pressKeys(_ view: NSView) {
        guard let keys = ProcessInfo.processInfo.environment["KUK_KEYS"] else { return }
        let codes: [String: (UInt16, String)] = [
            "space": (49, " "), "right": (124, "\u{F703}"), "left": (123, "\u{F702}"), "return": (36, "\r"),
            "f": (3, "f"), "z": (6, "z"), "h": (4, "h"), "i": (34, "i"), "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"),
        ]
        for k in keys.split(separator: ",").map(String.init) {
            guard let (code, chars) = codes[k], let e = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            view.keyDown(with: e)
        }
    }

    static func snapshot(_ view: NSView, to path: String) {
        guard let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dst, img, nil)
        CGImageDestinationFinalize(dst)
    }
}
