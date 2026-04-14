import SwiftUI

enum Tab: String, CaseIterable {
    case servers = "Серверы"
    case settings = "Настройки"
}

struct ContentView: View {
    var pm: ProcessManager
    var loc: LocationService
    var net: NetworkMonitor
    var setup: SetupService
    var subs: SubscriptionService

    @State private var tab: Tab = .servers
    @State private var connectedAt: Date?
    @State private var locationTimer: Timer?
    @State private var locationTask: Task<Void, Never>?
    @AppStorage("selectedServerID") private var selectedServerID = ""
    @AppStorage("xrayPath") private var xrayPath = ""
    @AppStorage("singBoxPath") private var singBoxPath = ""
    @AppStorage("bypassEnabled") private var bypassEnabled = true
    @AppStorage("bypassDomains") private var bypassDomainsRaw = ""
    @AppStorage("autoConnect") private var autoConnect = false

    private var bypassDomains: [String] {
        bypassDomainsRaw.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var selectedServer: Server? {
        subs.subscriptions.flatMap(\.servers).first { $0.id.uuidString == selectedServerID }
    }

    private var selectedSubscription: Subscription? {
        subs.subscriptions.first { sub in
            sub.servers.contains { $0.id.uuidString == selectedServerID }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider()

            Group {
                switch tab {
                case .servers:
                    ServersView(
                        pm: pm, loc: loc, net: net, setup: setup, subs: subs,
                        connectedAt: $connectedAt,
                        onConnect: doConnect,
                        onDisconnect: doDisconnect
                    )
                case .settings:
                    SettingsView(pm: pm, setup: setup)
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: tab)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loc.detect()
            setup.checkAll()
            if singBoxPath.isEmpty || !FileManager.default.isExecutableFile(atPath: singBoxPath) {
                singBoxPath = ProcessManager.findBinary("sing-box") ?? ""
            }
            if xrayPath.isEmpty || !FileManager.default.isExecutableFile(atPath: xrayPath) {
                xrayPath = ProcessManager.findBinary("xray") ?? ""
            }
            await subs.refreshAll()

            if autoConnect, !pm.isRunning, selectedServer != nil {
                doConnect()
            }
        }
        .onChange(of: setup.singBoxPath) { _, newPath in
            if let newPath, !newPath.isEmpty { singBoxPath = newPath }
        }
        .onChange(of: setup.xrayPath) { _, newPath in
            if let newPath, !newPath.isEmpty { xrayPath = newPath }
        }
        .onChange(of: pm.reconnectCount) {
            connectedAt = Date()
            startLocationTimer()
        }
        .onDisappear {
            locationTask?.cancel()
            locationTimer?.invalidate()
            locationTimer = nil
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                VStack(spacing: 0) {
                    Text(t.rawValue)
                        .font(.system(size: 14, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? .primary : .secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle()
                        .fill(tab == t ? Color.indigo : .clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
                .background(tab == t ? Color.secondary.opacity(0.08) : .clear)
                .onTapGesture { tab = t }
            }
        }
        .frame(height: 40)
    }

    // MARK: - Actions

    private func doConnect() {
        guard let server = selectedServer,
              let sub = selectedSubscription else {
            pm.logs.append("[Error: no server selected]")
            return
        }

        let engine = server.engine ?? sub.engine
        let binaryPath: String
        switch engine {
        case .singBox: binaryPath = singBoxPath
        case .xray: binaryPath = xrayPath
        }

        pm.connect(
            config: server.config,
            engine: engine,
            binaryPath: binaryPath,
            singBoxPath: singBoxPath,
            bypassDomains: bypassEnabled ? bypassDomains : []
        )
        connectedAt = Date()
        startLocationTimer()
    }

    private func doDisconnect() {
        pm.disconnect()
        connectedAt = nil
        locationTask?.cancel()
        locationTimer?.invalidate()
        locationTimer = nil
        locationTask = Task {
            for delay in [3, 5, 10] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                let oldIP = loc.ip
                await loc.detect()
                if loc.ip != oldIP { break }
            }
        }
    }

    private func startLocationTimer() {
        locationTask?.cancel()
        locationTimer?.invalidate()
        locationTask = Task {
            for delay in [3, 5, 10] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                let oldIP = loc.ip
                await loc.detect()
                if loc.ip != oldIP { break }
            }
        }
        locationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { await loc.detect() }
        }
    }
}
