import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: ViewerWindow!
    private var view: ViewerView!
    private var openedFiles = false

    func applicationWillFinishLaunching(_ n: Notification) {
        Debug.mark("willFinishLaunching")
        buildMenu()
        let screen = mouseScreen
        window = ViewerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        view = ViewerView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onClose = { [weak self] in self?.close() }
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
                self?.present()
                if let path = Debug.snapshotPath, let v = self?.view {
                    FileHandle.standardError.write("first image on screen after \(Debug.sinceLaunchMs()) ms\n".data(using: .utf8)!)
                    Debug.pressKeys(v)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { Debug.snapshot(v, to: path) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.present() }
        }
        view.open(images)
        if !firstOpen { present() }
    }

    private func present() {
        guard !window.isVisible || !NSApp.isActive else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ n: Notification) {
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
    }

    /// Esc hides instead of quitting: the process stays resident (with caches released),
    /// so the next open from Finder skips app launch entirely. Cmd+Q quits for real.
    private func close() {
        window.orderOut(nil)
        view.clear()
        NSApp.hide(nil)
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
