import Foundation
import SwiftUI

// Owns every service plus the connect/disconnect logic. This used to live in ContentView,
// which worked while a single view drove the whole UI. It is also what lets the bootstrap
// run at launch instead of waiting for a view to appear.
@Observable
@MainActor
final class AppState {
    let pm = ProcessManager()
    let loc = LocationService()
    let net = NetworkMonitor()
    let setup = SetupService()
    let subs = SubscriptionService()

    var connectedAt: Date?

    private var locationTimer: Timer?
    private var locationTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        observeReconnects()
    }

    // MARK: - Settings
    //
    // These read UserDefaults directly, which @Observable does not track. That is only safe
    // because the view editing a key holds the matching @AppStorage and re-renders itself,
    // reading AppState fresh on that render. Keep the @AppStorage in the editing view.

    var selectedServer: Server? {
        subs.subscriptions.lazy.flatMap(\.servers).first { $0.id == selectedServerID }
    }

    var bypassDomains: [String] {
        (defaults.string(forKey: "bypassDomains") ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var selectedServerID: String {
        defaults.string(forKey: "selectedServerID") ?? ""
    }

    private var selectedSubscription: Subscription? {
        subs.subscriptions.first { $0.servers.contains { $0.id == selectedServerID } }
    }

    // bool(forKey:) reports false for a key that was never written, which would silently
    // disable bypass on first launch — the @AppStorage default is true.
    private var activeBypassDomains: [String] {
        let enabled = defaults.object(forKey: "bypassEnabled") as? Bool ?? true
        return enabled ? bypassDomains : []
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        setup.checkAll()
        async let location: Void = loc.detect()
        async let feeds: Void = subs.refreshAll()
        _ = await (location, feeds)

        if defaults.bool(forKey: "autoConnect"), !pm.isRunning, selectedServer != nil {
            connect()
        }
    }

    func connect() {
        guard let server = selectedServer, let sub = selectedSubscription else {
            pm.logs.append("[Error: no server selected]")
            return
        }

        let engine = server.engine ?? sub.engine
        pm.connect(
            config: server.config,
            engine: engine,
            binaryPath: ProcessManager.findBinary(engine.rawValue) ?? "",
            singBoxPath: ProcessManager.findBinary(Engine.singBox.rawValue) ?? "",
            bypassDomains: activeBypassDomains
        )
        connectedAt = Date()
        startLocationTimer()
    }

    func disconnect() {
        pm.disconnect()
        connectedAt = nil
        locationTimer?.invalidate()
        locationTimer = nil
        locationTask?.cancel()
        locationTask = redetectLocation()
    }

    func routingChanged() {
        guard pm.isRunning else { return }
        pm.reconnect(bypassDomains: activeBypassDomains)
    }

    // MARK: - Location polling

    private func startLocationTimer() {
        locationTask?.cancel()
        locationTimer?.invalidate()
        locationTask = redetectLocation()
        locationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.loc.detect() }
        }
    }

    // TUN takes a while to carry traffic, so keep re-checking until the public IP moves.
    private func redetectLocation() -> Task<Void, Never> {
        Task {
            for delay in [3, 5, 10] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                let oldIP = loc.ip
                await loc.detect()
                if loc.ip != oldIP { break }
            }
        }
    }

    // A view can no longer watch reconnectCount: views come and go with the window.
    private func observeReconnects() {
        withObservationTracking {
            _ = pm.reconnectCount
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                connectedAt = Date()
                startLocationTimer()
                observeReconnects()
            }
        }
    }
}
