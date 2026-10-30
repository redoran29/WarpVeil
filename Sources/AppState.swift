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
    // stale set. Pinging it would measure ids that the launch's refresh is about to replace.
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

    var canConnect: Bool {
        isAuto ? !xrayServers.isEmpty : selectedServer != nil
    }

    var bypassDomains: [String] {
        (defaults.string(forKey: "bypassDomains") ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func subscription(of server: Server) -> Subscription? {
        subs.subscriptions.first { $0.servers.contains { $0.id == server.id } }
    }

    // What ping measures and Auto picks from: a sing-box config an earlier build stored cannot connect.
    private var xrayServers: [Server] {
        subs.subscriptions.flatMap { sub in
            sub.servers.filter { ($0.engine ?? sub.engine) == .xray }
        }
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
        async let feeds: Void = refreshFeeds(subs.subscriptions.filter { !$0.isManual })
        _ = await (location, feeds)

        if defaults.bool(forKey: "autoConnect"), !pm.isRunning, canConnect {
            connect()
        }

        isBootstrapped = true
        startUpdateChecks()
        startFeedRefreshes()
    }

    func connect() {
        guard !isAuto else {
            connectAuto()
            return
        }
        guard let server = selectedServer else {
            pm.logError("[Error: no server selected]")
            return
        }
        start(server, auto: false)
    }

    // Checked here, not at the click: an Auto connect measures first, and the download may begin
    // meanwhile.
    private func start(_ server: Server, auto: Bool) {
        // During the download: a session started now would be stopped again for the swap.
        guard updater.state != .installing else {
            pm.log(ProcessManager.updateHoldMessage)
            return
        }
        guard let sub = subscription(of: server) else { return }
        // Every server runs on xray. A sing-box config an earlier build stored is rebuilt by its
        // feed's next refresh; a manual one has to be added again.
        guard (server.engine ?? sub.engine) == .xray else {
            pm.logError(sub.isManual
                ? "[Error: \(server.name) is a sing-box config — add it again as a link or an xray config]"
                : "[Error: \(server.name) is still a sing-box config — refresh \(sub.name) to rebuild it]")
            return
        }
        activeServer = server
        activeIsAuto = auto
        pm.connect(
            config: server.config,
            xrayPath: ProcessManager.findBinary("xray") ?? "",
            bypassDomains: activeBypassDomains
        )
    }

    func disconnect() {
        pickTask?.cancel()
        pickTask = nil
        pm.disconnect()
    }

    func removeSubscription(_ id: UUID) {
        if subs.subscriptions.first(where: { $0.id == id })?
            .servers.contains(where: { $0.id == selectedServerID }) == true {
            selectedServerID = ""
        }
        subs.removeSubscription(id)
    }

    // A run under way — Auto's — already measures every server; starting over would kill its engines.
    func pingAll() {
        guard isBootstrapped, !ping.isRunning else { return }
        ping.start(xrayServers)
    }

    // Not gated on isRunning: a reconnect pending after wake has to pick the change up too.
    func routingChanged() {
        pm.reconnect(bypassDomains: activeBypassDomains)
    }

    // MARK: - Auto
    //
    // "Auto" connects to the lowest ping and, while connected, leaves a server that stops answering
    // or turns slow for the fastest one (owner, 2026-10-30). A move is a reconnect to one server,
    // so the exit address changes only then; a server chosen by hand is never left.

    static let autoServerID = "auto"
    var isAuto: Bool { selectedServerID == Self.autoServerID }

    // The server the session was started with, kept as it was: a refresh that drops it from its
    // feed does not stop the watch from leaving it. Whether Auto started it is the session's, not
    // the selection's: a tap only selects, so Auto picked while on a hand-picked server leaves it be.
    private(set) var activeServer: Server?
    private(set) var activeIsAuto = false
    private var pickTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    // The last reconnect to a server that still pinged best. A second failure soon after means
    // its sessions keep breaking, and the next best is taken instead.
    private var retried: (serverID: String, at: Date)?

    // An Auto connect still measuring, before any session exists.
    var isPicking: Bool { pickTask != nil }

    // The lowest ping on record, the first in the list on a tie.
    var fastestServer: Server? { fastest(excluding: nil) }

    private func fastest(excluding excludedID: String?) -> Server? {
        xrayServers
            .filter { $0.id != excludedID }
            .compactMap { server in delay(of: server).map { (server, $0) } }
            .min { $0.1 < $1.1 }?.0
    }

    func delay(of server: Server) -> Int? {
        guard case .delay(let milliseconds) = ping.results[server.id] else { return nil }
        return milliseconds
    }

    private func connectAuto() {
        guard pickTask == nil, !pm.isRunning else { return }
        pickTask = Task {
            // Older than 10 minutes, none, or none that answered: measured first.
            if fastestServer == nil || ping.lastFinished.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                pm.log("[Auto: measuring every server...]")
                await ping.run(xrayServers)
            }
            guard !Task.isCancelled else { return }
            pickTask = nil
            guard let server = fastestServer else {
                pm.logError("[Auto: no server answered — not connecting]")
                return
            }
            pm.log("[Auto: \(server.name), \(delay(of: server) ?? 0) ms]")
            start(server, auto: true)
        }
    }

    // A probe through the tunnel every 10 s, and one at once after a failure to confirm it. Two
    // that fail in a row, or three in a row slower than 1.5 s, and every server is measured.
    private func watchTunnel() -> Task<Void, Never> {
        Task {
            var failed = 0
            var slow = 0
            // A probe is a cold request — new connection, every handshake — so a distant server
            // can be slow by this measure and still the fastest; it is then left alone a while.
            var slowQuietUntil = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(for: failed > 0 ? .seconds(1) : .seconds(10))
                guard !Task.isCancelled else { return }
                guard activeIsAuto, let server = activeServer else { continue }
                let delay = await PingService.probeTunnel()
                guard !Task.isCancelled else { return }
                let isSlow = delay.map { $0 > .milliseconds(1500) } ?? true
                failed = delay == nil ? failed + 1 : 0
                slow = isSlow && Date() > slowQuietUntil ? slow + 1 : 0
                guard failed >= 2 || slow >= 3 else { continue }
                let isDead = failed >= 2
                failed = 0
                slow = 0
                if await !moveOff(server, isDead: isDead) {
                    slowQuietUntil = Date().addingTimeInterval(600)
                }
            }
        }
    }

    // A dead server is left for the fastest — the same one when it still pings best, since then
    // its session is what broke, unless that was just tried. A slow one is left only for another.
    // False when the tunnel stays on a slow server that is still the fastest.
    private func moveOff(_ server: Server, isDead: Bool) async -> Bool {
        pm.logError("[Auto: \(server.name) \(isDead ? "stopped answering" : "is slow") — measuring every server...]")
        await ping.run(xrayServers)
        guard !Task.isCancelled, activeIsAuto, pm.isTunnelUp else { return true }
        let justRetried = retried.map { $0.serverID == server.id && Date().timeIntervalSince($0.at) < 300 } ?? false
        guard let best = fastest(excluding: isDead && justRetried ? server.id : nil) else {
            pm.logError("[Auto: no server answered — staying on \(server.name)]")
            // The network itself is likely down; measuring again at once would only repeat that.
            try? await Task.sleep(for: .seconds(30))
            return true
        }
        guard best.id != server.id else {
            guard isDead else {
                pm.log("[Auto: \(server.name) still pings best — staying on it]")
                return false
            }
            retried = (server.id, Date())
            pm.reconnect(config: best.config, "[Auto: \(server.name) still pings best — reconnecting to it]")
            return true
        }
        activeServer = best
        pm.reconnect(config: best.config, "[Auto: moving to \(best.name), \(delay(of: best) ?? 0) ms]")
        return true
    }

    // MARK: - Feeds

    // Every feed at launch, then each once its own interval has passed: the app lives in the menu
    // bar for weeks. Asked hourly, so a Mac woken past the interval refreshes within the hour, and
    // a feed that is down is tried again an hour later.
    private func startFeedRefreshes() {
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshDueFeeds() }
        }
    }

    // A feed refreshing by hand right now is left to that refresh.
    private func refreshDueFeeds() async {
        let refreshing = subs.refreshingIDs
        await refreshFeeds(subs.subscriptions.filter { $0.isRefreshDue && !refreshing.contains($0.id) })
    }

    // Side by side: one unreachable feed at a 15 s timeout would hold up auto-connect behind the rest.
    private func refreshFeeds(_ feeds: [Subscription]) async {
        await withTaskGroup(of: Void.self) { group in
            for feed in feeds {
                group.addTask { await self.refreshFeed(feed) }
            }
        }
    }

    private func refreshFeed(_ feed: Subscription) async {
        guard await subs.refreshSubscription(feed.id) else {
            pm.logError("[\(feed.name) did not refresh — its servers are unchanged]")
            return
        }
        let count = subs.subscriptions.first { $0.id == feed.id }?.servers.count ?? 0
        pm.log("[\(feed.name) refreshed — \(count) server(s)]")
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
            // Held from the stop on, not during the download: a wake or a routing restart then is
            // still the user's tunnel, and should the update fail it has to come back. Only the
            // install that set the hold releases it — a second one, refused, never set it.
            var held = false
            var wasRunning = false
            let handedOver = await updater.install {
                held = true
                wasRunning = pm.isRunning || isPicking
                pm.connectHold = ProcessManager.updateHoldMessage
                disconnect()
                return await pm.awaitTeardown(timeout: .seconds(30))
            }
            // Its own hold only: a quit that began meanwhile holds connects until the app is gone.
            if handedOver {
                quit()
            } else if held, pm.connectHold == ProcessManager.updateHoldMessage {
                pm.connectHold = nil
                if wasRunning { connect() }
            }
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
            watchTask = watchTunnel()
        } else {
            connectedAt = nil
            watchTask?.cancel()
            watchTask = nil
            net.stop()
            locationTimer?.invalidate()
            locationTimer = nil
            locationTask?.cancel()
            locationTask = redetectLocation()
        }
    }
}
