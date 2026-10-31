import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: ViewerWindow!
    private var view: ViewerView!
    private var openedFiles = false
    private var presentFallback: DispatchWorkItem?

    func applicationWillFinishLaunching(_ n: Notification) {
        Debug.mark("willFinishLaunching")
        buildMenu()
        let screen = mouseScreen
        window = ViewerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        view = ViewerView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onClose = { [weak self] in self?.close() }
        view.onSwitchDisplay = { [weak self] in self?.moveToNextScreen() ?? false }
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        Debug.mark("window ready")
    }

    private var mouseScreen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Debug.mark("didFinishLaunching")
        // Files passed on the command line (`Kuk.app/Contents/MacOS/Kuk photo.jpg`).
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        if !openedFiles, !args.isEmpty { application(NSApp, open: args) }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        Debug.mark("open \(urls.count) urls")
        let images = urls.filter(ImageList.isImage)
        guard !images.isEmpty else { return }
        openedFiles = true
        let firstOpen = !window.isVisible
        if firstOpen {
            window.setFrame(mouseScreen.frame, display: false)
            // Show the window once the first image is decoded (no black flash), at most after 250 ms.
            view.onFirstImage = { [weak self] in
                self?.presentFallback?.cancel()
                self?.present()
                if let path = Debug.snapshotPath, let v = self?.view {
                    FileHandle.standardError.write("first image on screen after \(Debug.sinceLaunchMs()) ms\n".data(using: .utf8)!)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Debug.pressKeys(v) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { Debug.snapshot(v, to: path) }
                }
            }
            let fallback = DispatchWorkItem { [weak self] in self?.present() }
            presentFallback = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: fallback)
        }
        view.open(images)
        if !firstOpen { present() }
    }

    private func present() {
        guard !window.isVisible || !NSApp.isActive else { return }
        Debug.mark("present")
        CATransaction.begin()
        CATransaction.setCompletionBlock { Debug.mark("frame committed") }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        CATransaction.commit()
    }

    func applicationWillUnhide(_ n: Notification) { Debug.mark("will unhide") }
    func applicationDidUnhide(_ n: Notification) { Debug.mark("did unhide") }
    func applicationWillBecomeActive(_ n: Notification) { Debug.mark("will become active") }

    func applicationDidBecomeActive(_ n: Notification) {
        Debug.mark("became active")
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        Debug.mark("presentation options set")
    }

    /// Cycles the fullscreen window through the connected displays (main ↔ second with two).
    private func moveToNextScreen() -> Bool {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return false }
        let i = window.screen.flatMap { screens.firstIndex(of: $0) } ?? 0
        window.setFrame(screens[(i + 1) % screens.count].frame, display: true)
        view.displayChanged()
        return true
    }

    /// Esc hides instead of quitting: the process stays resident (with caches released),
    /// so the next open from Finder skips app launch entirely. Cmd+Q quits for real.
    private func close() {
        presentFallback?.cancel()
        view.onFirstImage = nil
        window.orderOut(nil)
        view.clear()
        NSApp.hide(nil)
        Debug.mark("closed")
    }

    /// No open dialog, ever: Kuk only shows what Finder hands it.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool { false }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Kuk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

Debug.mark("main")
let app = NSApplication.shared
Debug.mark("shared")
let delegate = AppDelegate()
app.delegate = delegate
Debug.mark("run")
app.run()
