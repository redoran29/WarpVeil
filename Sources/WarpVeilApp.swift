import SwiftUI

@main
struct WarpVeilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // macOS 14 offers no way to declare an App with no scenes at all. This one is never shown:
    // the Settings… item it would contribute is replaced so Cmd+, opens the real window instead.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                // The rail is the only page switcher and the only control that can bring it
                // back, so nothing may collapse the sidebar column.
                CommandGroup(replacing: .sidebar) { }
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
    private let app = AppState { NSApp.terminate(nil) }

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
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WarpVeil"
        // Turns close() into orderOut, so the SwiftUI graph and its @State survive hiding.
        window.isReleasedWhenClosed = false

        let host = NSHostingController(rootView: ContentView(app: app))
        // The window owns its size; SwiftUI only contributes the minimum the columns need.
        host.sizingOptions = [.minSize]
        host.view.autoresizingMask = [.width, .height]
        window.contentViewController = host
        // Assigning the controller collapses the content height to zero under every sizingOptions.
        window.setContentSize(NSSize(width: 960, height: 640))
        window.center()
        // Restores the last frame on later launches; the first launch keeps the centred one.
        window.setFrameAutosaveName("MainWindow")
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

    // Every quit path goes through here — Cmd+Q, the status menu, an update, and dev-run.sh's and
    // install.sh's AppleScript quit — so this is where the engines stop. A stop that fails leaves
    // the tunnel up and the app quits anyway: its xray outlives it until the next connect.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Synchronous: the .terminateNow path below exits without waiting for anything.
        app.ping.cancel()
        guard app.pm.isRunning else { return .terminateNow }
        app.disconnect()
        Task {
            await app.pm.awaitTeardown(timeout: 30)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Status Menu

    // Rebuilt on every open, so it always reflects live state without observing anything.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = app.pm.isTunnelUp
            ? "Connected — \(app.loc.flag) \(app.loc.ip)"
            : app.pm.isRunning ? "Connecting…" : "Disconnected"
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

        if let version = app.updater.availableVersion {
            let update = NSMenuItem(title: "Update to \(version)…", action: #selector(updateAction), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WarpVeil",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    @objc private func connectAction() { app.connect() }
    @objc private func disconnectAction() { app.disconnect() }
    @objc private func openAction() { showWindow() }
    @objc private func updateAction() { app.installUpdate() }

    // MARK: - Reactive State Observation

    private func observeState() {
        withObservationTracking {
            _ = app.pm.isRunning
            _ = app.pm.isTunnelUp
            _ = app.loc.flag
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateStatusIcon()
                observeState()
            }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let iconName = app.pm.isTunnelUp ? "checkmark.shield.fill" : app.pm.isRunning ? "shield" : "shield.slash"
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "WarpVeil")
        button.title = app.loc.flag.isEmpty ? "" : " \(app.loc.flag)"
    }
}
