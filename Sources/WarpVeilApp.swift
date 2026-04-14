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
    private let pm = ProcessManager()
    private let loc = LocationService()
    private let net = NetworkMonitor()
    private let setup = SetupService()
    private let subs = SubscriptionService()
    private var wasRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "shield.slash", accessibilityDescription: "WarpVeil")
            button.action = #selector(statusBarAction)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        let contentView = ContentView(pm: pm, loc: loc, net: net, setup: setup, subs: subs)
            .frame(width: 400, height: 640)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 640)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        observeState()
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
        let quit = NSMenuItem(title: "Закрыть WarpVeil", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quitApp() {
        if pm.isRunning { pm.disconnect() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Reactive State Observation

    private func observeState() {
        withObservationTracking {
            _ = pm.isRunning
            _ = loc.flag
            _ = net.hasTraffic
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateStatusIcon()
                if pm.isRunning != wasRunning {
                    wasRunning = pm.isRunning
                    if pm.isRunning { net.start() } else { net.stop() }
                }
                observeState()
            }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let iconName = pm.isRunning ? "checkmark.shield.fill" : "shield.slash"
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "WarpVeil")

        if pm.isRunning {
            button.title = " \(loc.flag)"
        } else if !loc.flag.isEmpty {
            button.title = " \(loc.flag)"
        } else {
            button.title = ""
        }
    }
}
