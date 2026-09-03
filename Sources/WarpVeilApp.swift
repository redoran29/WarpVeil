import SwiftUI

@main
struct WarpVeilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // macOS 14 offers no way to declare an App with no scenes at all. This one is never shown:
    // the Settings… item it would contribute is replaced so Cmd+, opens the real window instead.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.showWindow() }
                        .keyboardShortcut(",")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let app = AppState()
    private var wasRunning = false

    private static let windowWidth: CGFloat = 620

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "shield.slash", accessibilityDescription: "WarpVeil")

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        makeWindow()
        observeState()
        Task { await app.bootstrap() }
        showWindow()
    }

    // MARK: - Window

    private func makeWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WarpVeil"
        // Turns close() into orderOut, so the SwiftUI graph and its @State survive hiding.
        window.isReleasedWhenClosed = false

        // self.window is already assigned above: setting contentViewController triggers the
        // first height measurement, which calls straight back into fitWindow.
        let host = NSHostingController(rootView: ContentView(app: app) { [weak self] height in
            self?.fitWindow(toContentHeight: height)
        })
        // Default sizing options pin minSize == maxSize to the content's intrinsic size,
        // which leaves the window unable to change size from code.
        host.sizingOptions = []
        host.view.autoresizingMask = [.width, .height]
        window.contentViewController = host
        // Assigning a controller with no sizing options collapses the content height to zero.
        window.setContentSize(NSSize(width: Self.windowWidth, height: 640))
        window.center()
    }

    // Grows and shrinks the window to whatever the active page measured, keeping the title
    // bar anchored: NSWindow's origin is bottom-left, so the origin moves with the height.
    private func fitWindow(toContentHeight height: CGFloat) {
        let contentRect = NSRect(x: 0, y: 0, width: Self.windowWidth, height: height)
        let targetHeight = window.frameRect(forContentRect: contentRect).height

        var frame = window.frame
        guard abs(frame.height - targetHeight) > 0.5 else { return }
        frame.origin.y += frame.height - targetHeight
        frame.size.height = targetHeight

        guard window.isVisible else {
            window.setFrame(frame, display: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().setFrame(frame, display: true)
        }
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: - App Lifecycle

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Every quit path goes through here — Cmd+Q, the status menu, and dev-run.sh's AppleScript
    // quit. ProcessManager's willTerminate observer disconnects inside a Task, so a plain
    // terminate can exit before the root-owned engines are stopped.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard app.pm.isRunning else { return .terminateNow }
        app.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Status Menu

    // Rebuilt on every open, so it always reflects live state without observing anything.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = app.pm.isRunning
            ? "Connected — \(app.loc.flag) \(app.loc.ip)"
            : "Disconnected"
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))

        menu.addItem(.separator())

        let toggle = app.pm.isRunning
            ? NSMenuItem(title: "Disconnect", action: #selector(disconnectAction), keyEquivalent: "")
            : NSMenuItem(title: "Connect", action: #selector(connectAction), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let open = NSMenuItem(title: "Open WarpVeil", action: #selector(openAction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WarpVeil",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    @objc private func connectAction() { app.connect() }
    @objc private func disconnectAction() { app.disconnect() }
    @objc private func openAction() { showWindow() }

    // MARK: - Reactive State Observation

    private func observeState() {
        withObservationTracking {
            _ = app.pm.isRunning
            _ = app.loc.flag
            _ = app.net.hasTraffic
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateStatusIcon()
                if app.pm.isRunning != wasRunning {
                    wasRunning = app.pm.isRunning
                    if app.pm.isRunning { app.net.start() } else { app.net.stop() }
                }
                observeState()
            }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let iconName = app.pm.isRunning ? "checkmark.shield.fill" : "shield.slash"
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "WarpVeil")
        button.title = app.loc.flag.isEmpty ? "" : " \(app.loc.flag)"
    }
}
