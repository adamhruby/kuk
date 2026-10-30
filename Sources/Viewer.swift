import AppKit
import QuartzCore

final class ViewerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ViewerView: NSView {
    private(set) var files: [URL] = []
    private var index = 0
    private var current: URL? { files.indices.contains(index) ? files[index] : nil }

    private var mode = ZoomMode.saved
    private var shown: Decoded?
    private var scale: CGFloat = 1          // image px -> screen px
    private var origin = CGPoint.zero       // image rect origin, view points
    private var userZoomed = false
    private var swipeX: CGFloat = 0

    let loader = Loader()
    /// Called once, when the first image is on screen.
    var onFirstImage: (() -> Void)?
    var onClose: (() -> Void)?
    /// Moves the window to the next display; false when there is only one.
    var onSwitchDisplay: (() -> Bool)?

    private let imageLayer = CALayer()
    private let hud = Label(size: 15)
    private let info = Label(size: 12)
    private let help = Label(size: 12)
    private var hudTimer: Timer?
    private var showInfo = UserDefaults.standard.bool(forKey: "showInfo")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer?.addSublayer(imageLayer)
        for l in [hud, info, help] { addSubview(l) }
        hud.alphaValue = 0
        info.isHidden = !showInfo
        help.isHidden = true
        help.attributedStringValue = Self.helpText
        loader.onLoad = { [weak self] d in self?.loaded(d) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Available area: the screen minus the notch / menu bar strip.
    private var area: CGRect {
        let inset = window?.screen?.safeAreaInsets.top ?? 0
        return CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - inset)
    }

    private var layout: Layout {
        Layout(mode: mode, areaPx: CGSize(width: area.width * backing, height: area.height * backing))
    }

    private var displaySize: CGSize {
        guard let d = shown else { return .zero }
        return CGSize(width: d.fullSize.width * scale / backing, height: d.fullSize.height * scale / backing)
    }

    private func clampOrigin() {
        let s = displaySize, a = area
        origin.x = s.width <= a.width ? a.minX + (a.width - s.width) / 2 : min(a.minX, max(a.maxX - s.width, origin.x))
        origin.y = s.height <= a.height ? a.minY + (a.height - s.height) / 2 : min(a.minY, max(a.maxY - s.height, origin.y))
    }

    private func resetZoom() {
        guard let d = shown else { return }
        userZoomed = false
        scale = layout.baseScale(d.fullSize)
        let s = displaySize, a = area
        origin = CGPoint(x: a.midX - s.width / 2, y: a.midY - s.height / 2)
    }

    private func apply() {
        guard let d = shown else { imageLayer.contents = nil; return }
        clampOrigin()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if imageLayer.contents as! CGImage? !== d.image { imageLayer.contents = d.image }
        imageLayer.frame = CGRect(origin: origin, size: displaySize)
        imageLayer.magnificationFilter = scale >= 3 ? .nearest : .linear
        CATransaction.commit()
        updateInfo()
    }

    /// Re-fit after moving to another display (size, scale or notch may differ).
    func displayChanged() {
        resetZoom()
        apply()
        layoutLabels()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if !userZoomed { resetZoom() }
        apply()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !userZoomed { resetZoom() }
        apply()
        layoutLabels()
    }

    // MARK: Opening & navigation

    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        files = urls
        index = 0
        go(to: 0)
        guard urls.count == 1 else {
            files = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            index = files.firstIndex(of: first) ?? 0
            prefetch()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let list = ImageList.images(in: first.deletingLastPathComponent())
            DispatchQueue.main.async { [weak self] in
                guard let self, self.files == [first] else { return }
                let i = list.firstIndex { $0.lastPathComponent == first.lastPathComponent }
                guard let i else { return }
                self.files = list.enumerated().map { $0.offset == i ? first : $0.element }
                self.index = i
                self.prefetch()
                self.updateInfo()
            }
        }
    }

    /// Forget the folder and free decoded images.
    func clear() {
        files = []
        shown = nil
        loader.retain([])
        apply()
    }

    private func go(to i: Int) {
        guard !files.isEmpty else { return }
        index = ((i % files.count) + files.count) % files.count
        guard let url = current else { return }
        if let d = loader.cached(url) {
            shown = d
            resetZoom()
            apply()
        }
        loader.request(url, priority: .veryHigh)
        prefetch()
        updateInfo()
    }

    private func neighbour(_ offset: Int) -> URL {
        files[((index + offset) % files.count + files.count) % files.count]
    }

    private func prefetch() {
        let ahead = files.count > 1 ? [1, -1, 2] : []
        loader.retain(Set(([0] + ahead).map(neighbour)))
        for (n, o) in ahead.enumerated() {
            loader.request(neighbour(o), priority: n < 2 ? .high : .normal)
        }
    }

    private func loaded(_ d: Decoded) {
        guard d.url == current else { return }
        shown = d
        resetZoom()
        apply()
        Debug.mark("displayed \(d.url.lastPathComponent)")
        if let cb = onFirstImage { onFirstImage = nil; cb() }
    }

    // MARK: Zoom

    private func zoom(to newScale: CGFloat, at p: CGPoint) {
        guard shown != nil else { return }
        let old = displaySize
        let rel = CGPoint(x: (p.x - origin.x) / max(old.width, 1), y: (p.y - origin.y) / max(old.height, 1))
        scale = min(max(newScale, 0.01), 64)
        let s = displaySize
        origin = CGPoint(x: p.x - rel.x * s.width, y: p.y - rel.y * s.height)
        userZoomed = true
        apply()
    }

    private func zoom(by f: CGFloat, at p: CGPoint? = nil) {
        zoom(to: scale * f, at: p ?? CGPoint(x: area.midX, y: area.midY))
    }

    private func setMode(_ m: ZoomMode) {
        mode = m
        ZoomMode.saved = m
        resetZoom()
        apply()
        flash(m.title)
    }

    private func cycleMode() {
        let all = ZoomMode.allCases
        setMode(all[(all.firstIndex(of: mode)! + 1) % all.count])
    }

    /// Switch between the chosen mode and 100 % (or fit, when the mode already shows 100 %).
    private func toggleActualSize(at p: CGPoint? = nil) {
        guard let d = shown else { return }
        let base = layout.baseScale(d.fullSize)
        if abs(scale - base) > 0.001 {
            resetZoom(); apply()
        } else {
            zoom(to: abs(base - 1) < 0.001 ? fitScale(d) : 1, at: p ?? CGPoint(x: area.midX, y: area.midY))
        }
        flash("\(Int((scale * 100).rounded())) %")
    }

    // MARK: Actions

    private func openInPhotoshop() {
        guard let url = current else { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.Photoshop") else {
            flash("Photoshop not found"); return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func copyPath() {
        guard let url = current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        flash("Path copied")
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        NSCursor.setHiddenUntilMouseMoves(true)
        let shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 123: go(to: index - 1)                       // ←
        case 124: go(to: index + 1)                       // →
        case 49: go(to: index + (shift ? -1 : 1))         // space
        case 126: pan(dy: -120)                           // ↑
        case 125: pan(dy: 120)                            // ↓
        case 115: go(to: 0)                               // home
        case 119: go(to: files.count - 1)                 // end
        case 36, 76: openInPhotoshop()                    // return / enter
        case 53: onClose?()                               // esc
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "1": setMode(.realSize)
            case "2": setMode(.fitAll)
            case "3": setMode(.fitSmaller)
            case "4": setMode(.fitLarger)
            case "+", "=": zoom(by: 1.25)
            case "-": zoom(by: 1 / 1.25)
            case "0": resetZoom(); apply()
            case "f": cycleMode()
            case "z": toggleActualSize()
            case "i": toggleInfo()
            case "h": help.isHidden.toggle(); layoutLabels()
            case "d": if onSwitchDisplay?() == false { flash("No other display") }
            case "q": onClose?()
            default: super.keyDown(with: e)
            }
        }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        switch (e.charactersIgnoringModifiers?.lowercased(), flags.contains(.shift)) {
        case ("c", true): copyPath()
        case ("=", _), ("+", _): zoom(by: 1.25)
        case ("-", _): zoom(by: 1 / 1.25)
        case ("0", _): resetZoom(); apply()
        case ("w", false): onClose?()
        default: return false
        }
        return true
    }

    private func pan(dy: CGFloat) {
        origin.y += dy
        apply()
    }

    // MARK: Mouse & trackpad

    private func loc(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || !e.hasPreciseScrollingDeltas {
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : (e.scrollingDeltaY > 0 ? 0.14 : e.scrollingDeltaY < 0 ? -0.14 : 0)
            if dy != 0 { zoom(by: exp(dy), at: loc(e)) }
            return
        }
        let s = displaySize
        let pannable = s.width > area.width + 1 || s.height > area.height + 1
        if pannable {
            origin.x += e.scrollingDeltaX
            origin.y -= e.scrollingDeltaY
            apply()
            return
        }
        // Two-finger horizontal swipe flips images when nothing to pan.
        if e.phase == .began { swipeX = 0 }
        swipeX += e.scrollingDeltaX
        if e.phase == .ended || e.phase == .cancelled {
            if swipeX < -60 { go(to: index + 1) } else if swipeX > 60 { go(to: index - 1) }
            swipeX = 0
        }
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 + e.magnification, at: loc(e))
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { toggleActualSize(at: loc(e)) }
    }

    private func fitScale(_ d: Decoded) -> CGFloat {
        Layout(mode: .fitAll, areaPx: layout.areaPx).baseScale(d.fullSize)
    }

    override func mouseDragged(with e: NSEvent) {
        origin.x += e.deltaX
        origin.y -= e.deltaY
        apply()
    }

    // MARK: HUD / info

    private func toggleInfo() {
        showInfo.toggle()
        UserDefaults.standard.set(showInfo, forKey: "showInfo")
        info.isHidden = !showInfo
        updateInfo()
    }

    private func updateInfo() {
        guard showInfo, let url = current else { return }
        var parts = [url.lastPathComponent, "\(index + 1) / \(files.count)"]
        if let d = shown, d.url == url {
            parts.append("\(Int(d.fullSize.width)) × \(Int(d.fullSize.height))")
            if let p = d.profile { parts.append(p) }
            if let b = d.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)) }
            parts.append("\(Int((scale * 100).rounded())) %")
        }
        parts.append(mode.title)
        info.stringValue = parts.joined(separator: "   ·   ")
        layoutLabels()
    }

    private func flash(_ text: String) {
        hud.stringValue = text
        layoutLabels()
        hud.alphaValue = 1
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self?.hud.animator().alphaValue = 0 }
        }
    }

    private func layoutLabels() {
        hud.sizeToFit()
        hud.frame.origin = CGPoint(x: (bounds.width - hud.frame.width) / 2, y: area.maxY - hud.frame.height - 40)
        info.sizeToFit()
        info.frame.origin = CGPoint(x: 16, y: 16)
        help.sizeToFit()
        help.frame.origin = CGPoint(x: 16, y: area.maxY - help.frame.height - 16)
    }

    private static let helpText: NSAttributedString = {
        let rows: [(String, String)] = [
            ("→  ←  Space", "Next / previous image"),
            ("Z", "Toggle zoom mode ↔ 100 %"),
            ("F", "Cycle zoom modes"),
            ("1  2  3  4", "100 % · Fit all · Fit smaller only · Fit larger only"),
            ("+  −  scroll  pinch", "Zoom"),
            ("0", "Reset zoom"),
            ("Drag  ↑  ↓", "Pan"),
            ("Double-click", "Toggle zoom mode ↔ 100 %"),
            ("Home  End", "First / last image"),
            ("Return", "Open in Photoshop"),
            ("⇧⌘C", "Copy file path"),
            ("I", "Info bar"),
            ("D", "Move to next display"),
            ("H", "This help"),
            ("Esc", "Close"),
            ("⌘Q", "Quit"),
        ]
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 150)]
        para.lineSpacing = 3
        let out = NSMutableAttributedString()
        for (i, (key, action)) in rows.enumerated() {
            out.append(NSAttributedString(string: key, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para]))
            out.append(NSAttributedString(string: "\t" + action + (i < rows.count - 1 ? "\n" : ""), attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: para]))
        }
        return out
    }()
}

/// Small rounded translucent label.
final class Label: NSTextField {
    init(size: CGFloat) {
        super.init(frame: .zero)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        font = .systemFont(ofSize: size, weight: .medium)
        textColor = .white
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 8
    }
    required init?(coder: NSCoder) { fatalError() }

    private let pad = CGSize(width: 10, height: 5)

    override func sizeToFit() {
        let s = attributedStringValue.boundingRect(with: CGSize(width: 10000, height: 10000), options: .usesLineFragmentOrigin)
        frame.size = CGSize(width: ceil(s.width) + pad.width * 2, height: ceil(s.height) + pad.height * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        attributedStringValue.draw(with: bounds.insetBy(dx: pad.width, dy: pad.height), options: .usesLineFragmentOrigin)
    }
}
