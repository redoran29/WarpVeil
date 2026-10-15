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
    let ping = PingService()
    let updater = Updater()

    var connectedAt: Date?
    private var tunnelWasUp = false

    // Servers load synchronously in SubscriptionService.init, so the Servers page appears with a
    // stale set. Pinging it would measure ids that refreshAll is about to replace.
    private(set) var isBootstrapped = false

    // Observable, unlike the @AppStorage-mirrored keys below: two columns show the selection and
    // only one writes it, and a reader had to carry a phantom @AppStorage for a key it never
    // edited just to be invalidated. Persisted on write.
    var selectedServerID: String {
        didSet { defaults.set(selectedServerID, forKey: "selectedServerID") }
    }

    private var locationTimer: Timer?
    private var locationTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    // The app's own quit, which goes through applicationShouldTerminate; AppKit stays with the
    // delegate.
    private let quit: () -> Void

    init(quit: @escaping () -> Void) {
        self.quit = quit
        selectedServerID = defaults.string(forKey: "selectedServerID") ?? ""
        observeTunnel()
    }

    // MARK: - Settings
    //
    // bypassDomains reads UserDefaults directly, which @Observable does not track. That is only
    // safe because RoutingView both edits the key and holds the matching @AppStorage, so it
    // re-renders itself and reads AppState fresh. Keep that @AppStorage where the editing is.

    var selectedServer: Server? {
        subs.subscriptions.lazy.flatMap(\.servers).first { $0.id == selectedServerID }
    }

    var bypassDomains: [String] {
        (defaults.string(forKey: "bypassDomains") ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var selectedSubscription: Subscription? {
        subs.subscriptions.first { $0.servers.contains { $0.id == selectedServerID } }
    }

    // bool(forKey:) reports false for a key that was never written, which would silently
    // disable bypass on first launch — the @AppStorage default is true. Each row is normalized
    // on its own: an older build stored them as typed, and a row that does not normalize is
    // flagged on the Routing page and left out.
    private var activeBypassDomains: [String] {
        guard defaults.object(forKey: "bypassEnabled") as? Bool ?? true else { return [] }
        var seen = Set<String>()
        return bypassDomains.compactMap(BypassService.normalizeDomain).filter { seen.insert($0).inserted }
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

        isBootstrapped = true
        startUpdateChecks()
    }

    func connect() {
        guard let server = selectedServer, let sub = selectedSubscription else {
            pm.logs.append("[Error: no server selected]")
            return
        }

        // Every server runs on xray. A sing-box config an earlier build stored is rebuilt by its
        // feed's next refresh; a manual one has to be added again.
        guard (server.engine ?? sub.engine) == .xray else {
            pm.logs.append(sub.isManual
                ? "[Error: \(server.name) is a sing-box config — add it again as a link or an xray config]"
                : "[Error: \(server.name) is still a sing-box config — refresh \(sub.name) to rebuild it]")
            return
        }
        pm.connect(
            config: server.config,
            xrayPath: ProcessManager.findBinary("xray") ?? "",
            singBoxPath: ProcessManager.findBinary("sing-box") ?? "",
            bypassDomains: activeBypassDomains
        )
    }

    func disconnect() {
        pm.disconnect()
    }

    func removeSubscription(_ id: UUID) {
        if subs.subscriptions.first(where: { $0.id == id })?
            .servers.contains(where: { $0.id == selectedServerID }) == true {
            selectedServerID = ""
        }
        subs.removeSubscription(id)
    }

    func pingAll() {
        guard isBootstrapped else { return }
        ping.start(subs.subscriptions.flatMap { sub in
            sub.servers.filter { ($0.engine ?? sub.engine) == .xray }
        })
    }

    // Not gated on isRunning: a reconnect pending after wake has to pick the change up too.
    func routingChanged() {
        pm.reconnect(bypassDomains: activeBypassDomains)
    }

    // MARK: - Updates

    // Once after launch, then asked hourly and due a day after the last answer: the app lives in
    // the menu bar for weeks at a time. The first check waits out the TUN coming up under an
    // auto-connect.
    private func startUpdateChecks() {
        Task {
            try? await Task.sleep(for: .seconds(15))
            await updater.checkIfDue()
        }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.updater.checkIfDue() }
        }
    }

    // disconnect() also cancels a pending start or restart, which would otherwise bring engines
    // up while the app is on its way out. The swap waits for this process to exit.
    func installUpdate() {
        Task {
            let handedOver = await updater.install {
                pm.isHeldForUpdate = true
                disconnect()
                return await pm.awaitTeardown(timeout: 30)
            }
            if handedOver { quit() } else { pm.isHeldForUpdate = false }
        }
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

    // The tunnel coming up starts the uptime, the speed monitor and the location polling, and going
    // down stops them — a connect, a restart and an engine's exit alike. A view cannot watch this:
    // views come and go with the window.
    private func observeTunnel() {
        withObservationTracking {
            _ = pm.isTunnelUp
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                tunnelChanged()
                observeTunnel()
            }
        }
    }

    private func tunnelChanged() {
        guard pm.isTunnelUp != tunnelWasUp else { return }
        tunnelWasUp = pm.isTunnelUp
        if tunnelWasUp {
            connectedAt = Date()
            net.start()
            startLocationTimer()
        } else {
            connectedAt = nil
            net.stop()
            locationTimer?.invalidate()
            locationTimer = nil
            locationTask?.cancel()
            locationTask = redetectLocation()
        }
    }
}
