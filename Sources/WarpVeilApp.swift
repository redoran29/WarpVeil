import SwiftUI

@main
struct WarpVeilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let app = AppState()
    private var wasRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "shield.slash", accessibilityDescription: "WarpVeil")
            button.action = #selector(statusBarAction)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        let contentView = ContentView(app: app)
            .frame(width: 400, height: 640)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 640)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        observeState()
        Task { await app.bootstrap() }
    }

    // MARK: - Status Bar Actions

    @objc private func statusBarAction(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit WarpVeil", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quitApp() {
        if app.pm.isRunning { app.pm.disconnect() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

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

        if app.pm.isRunning {
            button.title = " \(app.loc.flag)"
        } else if !app.loc.flag.isEmpty {
            button.title = " \(app.loc.flag)"
        } else {
            button.title = ""
        }
    }
}
