import AppKit

/// Testing aid: with KUK_SNAPSHOT=/path.png set, renders the view's layers to a PNG
/// shortly after the first image appears and prints the time since process start.
/// `defaults write local.kuk.viewer timingLog -bool true` appends the same timing marks
/// to ~/Library/Logs/Kuk.log, for measuring real opens from Finder.
enum Debug {
    static var snapshotPath: String? { ProcessInfo.processInfo.environment["KUK_SNAPSHOT"] }

    static let logFile: FileHandle? = {
        guard UserDefaults.standard.bool(forKey: "timingLog") else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Kuk.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()

    static let enabled = snapshotPath != nil || logFile != nil
    /// KUK_CONFIRM=1 skips confirmation dialogs (tests only).
    static let autoConfirm = ProcessInfo.processInfo.environment["KUK_CONFIRM"] == "1"
    /// KUK_DRYRUN=1 prepares files for other apps without opening them (tests only).
    static let dryRun = ProcessInfo.processInfo.environment["KUK_DRYRUN"] == "1"

    static func mark(_ label: String) {
        guard enabled else { return }
        let line = "\(sinceLaunchMs()) ms  [\(String(format: "%.3f", Date().timeIntervalSince1970))]  \(label)\n".data(using: .utf8)!
        (logFile ?? FileHandle.standardError).write(line)
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
            "space": (49, " "), "esc": (53, "\u{1b}"), "backspace": (51, "\u{7f}"), "right": (124, "\u{F703}"), "up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "left": (123, "\u{F702}"), "return": (36, "\r"),
            "c": (8, "c"), "=": (24, "="), "f": (3, "f"), "d": (2, "d"), "z": (6, "z"), "h": (4, "h"), "i": (34, "i"), "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"),
        ]
        for var k in keys.split(separator: ",").map(String.init) {
            var flags: NSEvent.ModifierFlags = []
            if k.hasPrefix("cmd+") { flags.insert(.command); k.removeFirst(4) }
            if k.hasPrefix("shift+") { flags.insert(.shift); k.removeFirst(6) }
            guard let (code, chars) = codes[k], let e = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            Debug.mark("key \(k)")
            if !flags.contains(.command) || !view.performKeyEquivalent(with: e) { view.keyDown(with: e) }
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
