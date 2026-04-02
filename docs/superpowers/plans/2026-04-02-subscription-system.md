# Subscription System & UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace manual config editing with subscription-based server management and a two-column server browser UI.

**Architecture:** New `SubscriptionService` fetches configs from 3x-ui subscription URLs, parses sing-box/xray JSON into individual servers, stores them in a JSON file. The UI switches from 4-tab layout to 2-tab (Servers + Settings), with a two-column main screen showing server groups on the left and connection controls on the right.

**Tech Stack:** Swift 5.10, SwiftUI, macOS 14+, URLSession, Codable, JSONSerialization

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/Models.swift` | Create | `Engine`, `Subscription`, `Server` types |
| `Sources/SubscriptionService.swift` | Create | Fetch, parse, save/load subscriptions |
| `Sources/ServersView.swift` | Create | Two-column main screen (server list + connection panel) |
| `Sources/ContentView.swift` | Modify | 2 tabs, pass SubscriptionService, wider window |
| `Sources/SettingsView.swift` | Modify | Absorb Routing + Setup sections |
| `Sources/ProcessManager.swift` | Modify | Simplified connect() signature |
| `Sources/WarpVeilApp.swift` | Modify | Init SubscriptionService, window size 600×500 |
| `Sources/DashboardView.swift` | Delete | Replaced by ServersView |
| `Sources/RoutingView.swift` | Delete | Content moves into SettingsView |

---

### Task 1: Data Models

**Files:**
- Create: `Sources/Models.swift`

- [ ] **Step 1: Create Models.swift with Engine, Server, Subscription**

```swift
import Foundation

enum Engine: String, Codable, CaseIterable {
    case singBox = "sing-box"
    case xray = "xray"
}

struct Server: Codable, Identifiable {
    let id: UUID
    var name: String
    var protocolType: String
    var address: String
    var config: String

    init(name: String, protocolType: String, address: String, config: String) {
        self.id = UUID()
        self.name = name
        self.protocolType = protocolType
        self.address = address
        self.config = config
    }
}

struct Subscription: Codable, Identifiable {
    let id: UUID
    var name: String
    var url: String
    var isManual: Bool
    var engine: Engine
    var servers: [Server]
    var lastUpdated: Date?

    init(name: String, url: String = "", isManual: Bool = false, engine: Engine = .singBox) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.isManual = isManual
        self.engine = engine
        self.servers = []
        self.lastUpdated = nil
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `Cmd+B` in Xcode
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Models.swift
git commit -m "feat: add data models for subscriptions and servers"
```

---

### Task 2: SubscriptionService — Save/Load

**Files:**
- Create: `Sources/SubscriptionService.swift`

- [ ] **Step 1: Create SubscriptionService with save/load and config directory**

```swift
import Foundation

@Observable
@MainActor
final class SubscriptionService {
    var subscriptions: [Subscription] = []

    private let configDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/warpveil")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var filePath: URL {
        configDir.appendingPathComponent("subscriptions.json")
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: filePath),
              let decoded = try? JSONDecoder().decode([Subscription].self, from: data)
        else { return }
        subscriptions = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        try? data.write(to: filePath, options: .atomic)
    }

    func addSubscription(_ sub: Subscription) {
        subscriptions.append(sub)
        save()
    }

    func removeSubscription(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        save()
    }

    func updateSubscription(_ sub: Subscription) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == sub.id }) else { return }
        subscriptions[idx] = sub
        save()
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `Cmd+B` in Xcode
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/SubscriptionService.swift
git commit -m "feat: add SubscriptionService with save/load"
```

---

### Task 3: SubscriptionService — Fetch & Parse

**Files:**
- Modify: `Sources/SubscriptionService.swift`

- [ ] **Step 1: Add fetch method that downloads subscription URL**

Add to `SubscriptionService`, after the `updateSubscription` method:

```swift
    func refreshSubscription(_ id: UUID) async {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }),
              !subscriptions[idx].isManual,
              let url = buildURL(for: subscriptions[idx])
        else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = String(data: data, encoding: .utf8) else { return }
            let servers = parseConfig(json, engine: subscriptions[idx].engine)
            subscriptions[idx].servers = servers
            subscriptions[idx].lastUpdated = Date()
            save()
        } catch {
            // Network error — keep existing servers
        }
    }

    func refreshAll() async {
        for sub in subscriptions where !sub.isManual {
            await refreshSubscription(sub.id)
        }
    }

    private func buildURL(for sub: Subscription) -> URL? {
        guard var components = URLComponents(string: sub.url) else { return nil }
        var items = components.queryItems ?? []
        let format = sub.engine == .singBox ? "singbox" : "xray"
        items.removeAll { $0.name == "format" }
        items.append(URLQueryItem(name: "format", value: format))
        components.queryItems = items
        return components.url
    }
```

- [ ] **Step 2: Add sing-box config parser**

Add to `SubscriptionService`:

```swift
    private func parseConfig(_ json: String, engine: Engine) -> [Server] {
        switch engine {
        case .singBox: return parseSingBox(json)
        case .xray: return parseXray(json)
        }
    }

    private static let vpnTypesSingBox: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks", "shadowtls",
        "hysteria", "hysteria2", "tuic", "wireguard"
    ]

    private static let serviceTypesSingBox: Set<String> = [
        "direct", "block", "dns", "selector", "urltest"
    ]

    private func parseSingBox(_ json: String) -> [Server] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]]
        else { return [] }

        let serviceOutbounds = outbounds.filter {
            guard let type = $0["type"] as? String else { return false }
            return Self.serviceTypesSingBox.contains(type)
        }

        var servers: [Server] = []
        for ob in outbounds {
            guard let type = ob["type"] as? String,
                  Self.vpnTypesSingBox.contains(type) else { continue }

            let name = ob["tag"] as? String ?? type
            let host = ob["server"] as? String ?? "?"
            let port = ob["server_port"] as? Int ?? 0
            let address = "\(host):\(port)"

            var modifiedRoot = root
            modifiedRoot["outbounds"] = [ob] + serviceOutbounds
            let config = serializeJSON(modifiedRoot) ?? ""

            servers.append(Server(name: name, protocolType: type, address: address, config: config))
        }
        return servers
    }
```

- [ ] **Step 3: Add xray config parser**

Add to `SubscriptionService`:

```swift
    private static let vpnTypesXray: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks"
    ]

    private static let serviceTypesXray: Set<String> = [
        "freedom", "blackhole", "dns"
    ]

    private func parseXray(_ json: String) -> [Server] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]]
        else { return [] }

        let serviceOutbounds = outbounds.filter {
            guard let proto = $0["protocol"] as? String else { return false }
            return Self.serviceTypesXray.contains(proto)
        }

        var servers: [Server] = []
        for ob in outbounds {
            guard let proto = ob["protocol"] as? String,
                  Self.vpnTypesXray.contains(proto) else { continue }

            let name = ob["tag"] as? String ?? proto
            let address: String
            if let settings = ob["settings"] as? [String: Any],
               let vnext = settings["vnext"] as? [[String: Any]],
               let first = vnext.first {
                let host = first["address"] as? String ?? "?"
                let port = first["port"] as? Int ?? 0
                address = "\(host):\(port)"
            } else if let settings = ob["settings"] as? [String: Any],
                      let srvs = settings["servers"] as? [[String: Any]],
                      let first = srvs.first {
                let host = first["address"] as? String ?? "?"
                let port = first["port"] as? Int ?? 0
                address = "\(host):\(port)"
            } else {
                address = "?"
            }

            var modifiedRoot = root
            modifiedRoot["outbounds"] = [ob] + serviceOutbounds
            let config = serializeJSON(modifiedRoot) ?? ""

            servers.append(Server(name: name, protocolType: proto, address: address, config: config))
        }
        return servers
    }

    private func serializeJSON(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }
```

- [ ] **Step 4: Add method to parse manual JSON config**

Add to `SubscriptionService`:

```swift
    func addManualConfig(name: String, json: String, engine: Engine) {
        var sub = Subscription(name: name, isManual: true, engine: engine)
        sub.servers = parseConfig(json, engine: engine)
        if sub.servers.isEmpty {
            // If parsing found no VPN outbounds, store as single custom server
            sub.servers = [Server(name: name, protocolType: "custom", address: "—", config: json)]
        }
        sub.lastUpdated = Date()
        subscriptions.append(sub)
        save()
    }
```

- [ ] **Step 5: Build to verify compilation**

Run: `Cmd+B` in Xcode
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Sources/SubscriptionService.swift
git commit -m "feat: add subscription fetch and config parsing for sing-box and xray"
```

---

### Task 4: Simplify ProcessManager.connect()

**Files:**
- Modify: `Sources/ProcessManager.swift`

- [ ] **Step 1: Change connect() signature to accept config + engine**

Replace the existing `connect()` method signature and the `lastConnection` property. In `ProcessManager.swift`:

Replace:
```swift
    private var lastConnection: (singBoxPath: String, singBoxConfig: String,
                                  xrayPath: String, xrayConfig: String,
                                  bypassDomains: [String])?
```
With:
```swift
    private var lastConnection: (config: String, engine: Engine,
                                  binaryPath: String, bypassDomains: [String])?
```

Replace the entire `connect()` method (lines 138-215) with:
```swift
    func connect(
        config: String, engine: Engine,
        binaryPath: String, bypassDomains: [String] = []
    ) {
        guard !isRunning else { return }
        guard !config.isEmpty else {
            logs.append("[Error: no config provided]")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            logs.append("[Error: binary not found at \(binaryPath)]")
            return
        }

        lastConnection = (config, engine, binaryPath, bypassDomains)

        let finalConfig: String
        let configFile: String
        switch engine {
        case .singBox:
            finalConfig = BypassService.injectSingBox(config, domains: bypassDomains)
            configFile = singboxConfigFile
        case .xray:
            finalConfig = BypassService.injectXray(config, domains: bypassDomains)
            configFile = xrayConfigFile
        }

        FileManager.default.createFile(atPath: configFile, contents: finalConfig.data(using: .utf8),
                                        attributes: [.posixPermissions: 0o600])

        if !bypassDomains.isEmpty {
            logs.append("[Bypass] \(bypassDomains.count) domain(s) will route direct")
        }

        logs.append(isPasswordless ? "[Connecting...]" : "[Connecting (password prompt)...]")

        FileManager.default.createFile(atPath: logFile, contents: nil)
        let script = buildScript(engine: engine, binaryPath: binaryPath, configFile: configFile)
        FileManager.default.createFile(atPath: runScript, contents: script.data(using: .utf8),
                                        attributes: [.posixPermissions: 0o700])

        startLogTail()

        let process = Process()
        if isPasswordless {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["/bin/bash", runScript]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", """
                do shell script "bash '\(runScript)'" with administrator privileges
                """]
        }

        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.isRunning = false
                self.stopLogTail()
                self.logs.append("[Disconnected (exit \(status))]")
            }
        }

        do {
            try process.run()
            helperProcess = process
            isRunning = true
        } catch {
            logs.append("[Error: \(error.localizedDescription)]")
            stopLogTail()
        }
    }
```

- [ ] **Step 2: Update buildScript to accept engine + binaryPath + configFile**

Replace the existing `buildScript()` method with:
```swift
    private func buildScript(engine: Engine, binaryPath: String, configFile: String) -> String {
        var cmds = ["#!/bin/bash", "cd /tmp", "exec > \(Self.shellEscape(logFile)) 2>&1"]
        cmds.append("pkill -f 'sing-box run' 2>/dev/null; pkill -f 'xray run' 2>/dev/null; sleep 1")

        let label = engine == .singBox ? "sing-box" : "xray"
        let configFlag = engine == .singBox ? "-c" : "-config"
        cmds.append("echo '[\(label)] starting...'")
        cmds.append("\(Self.shellEscape(binaryPath)) run \(configFlag) \(Self.shellEscape(configFile)) &")
        cmds.append("VPN_PID=$!")
        cmds.append("echo '[\(label)] started pid='$VPN_PID")

        cmds.append("""
            cleanup() { echo '[stopping...]'; kill $VPN_PID 2>/dev/null; wait; echo '[stopped]'; exit 0; }
            trap cleanup TERM INT
            wait
            """)

        return cmds.joined(separator: "\n")
    }
```

- [ ] **Step 3: Update handleWake() to use new signature**

Replace the `handleWake()` method with:
```swift
    private func handleWake() {
        guard let params = lastConnection, isRunning else { return }
        logs.append("[System woke up — reconnecting...]")
        reconnectTask?.cancel()
        helperProcess?.terminate()
        helperProcess = nil
        stopLogTail()
        killVPNProcesses()
        isRunning = false

        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            connect(config: params.config, engine: params.engine,
                    binaryPath: params.binaryPath, bypassDomains: params.bypassDomains)
            reconnectCount += 1
        }
    }
```

- [ ] **Step 4: Update reconnect() to use new signature**

Replace the `reconnect()` method with:
```swift
    func reconnect(bypassDomains: [String]) {
        guard isRunning, let params = lastConnection else { return }
        logs.append("[Routing changed — reconnecting...]")
        reconnectTask?.cancel()
        helperProcess?.terminate()
        helperProcess = nil
        stopLogTail()
        killVPNProcesses()
        isRunning = false

        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            connect(config: params.config, engine: params.engine,
                    binaryPath: params.binaryPath, bypassDomains: bypassDomains)
            reconnectCount += 1
        }
    }
```

- [ ] **Step 5: Build to verify compilation**

Run: `Cmd+B` in Xcode
Expected: BUILD SUCCEEDED (may have errors in ContentView — will be fixed in Task 7)

- [ ] **Step 6: Commit**

```bash
git add Sources/ProcessManager.swift
git commit -m "refactor: simplify ProcessManager.connect() to accept config + engine"
```

---

### Task 5: ServersView — Main Two-Column Screen

**Files:**
- Create: `Sources/ServersView.swift`

- [ ] **Step 1: Create ServersView with two-column layout**

```swift
import SwiftUI

struct ServersView: View {
    var pm: ProcessManager
    var loc: LocationService
    var net: NetworkMonitor
    var setup: SetupService
    var subs: SubscriptionService
    @Binding var connectedAt: Date?
    var onConnect: () -> Void
    var onDisconnect: () -> Void

    @AppStorage("selectedServerID") private var selectedServerID = ""
    @State private var showAddSheet = false

    var selectedServer: Server? {
        subs.subscriptions.flatMap(\.servers).first { $0.id.uuidString == selectedServerID }
    }

    var body: some View {
        HSplitView {
            serverList
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
            connectionPanel
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Server List (Left Column)

    private var serverList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Servers")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Task { await subs.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if subs.subscriptions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No subscriptions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Add Subscription") { showAddSheet = true }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(subs.subscriptions) { sub in
                            SubscriptionGroupView(
                                sub: sub,
                                selectedServerID: $selectedServerID,
                                onRefresh: { Task { await subs.refreshSubscription(sub.id) } },
                                onDelete: { subs.removeSubscription(sub.id) }
                            )
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSubscriptionSheet(subs: subs)
        }
    }

    // MARK: - Connection Panel (Right Column)

    private var connectionPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            if !setup.allInstalled {
                setupBanner
                    .padding(.bottom, 12)
            }

            connectButton
                .padding(.bottom, 16)

            statusBlock
                .padding(.bottom, 16)

            if pm.isRunning {
                statsRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                SparklineView(downloadData: net.downloadHistory, uploadData: net.uploadHistory)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Spacer()

            logSection
        }
    }

    // MARK: - Connect Button

    private var connectButton: some View {
        Button {
            if pm.isRunning { onDisconnect() } else { onConnect() }
        } label: {
            ZStack {
                Circle()
                    .fill(pm.isRunning ? Color.green.opacity(0.15) : Color.secondary.opacity(0.08))
                    .frame(width: 100, height: 100)

                Circle()
                    .fill(pm.isRunning ? Color.green.opacity(0.25) : Color.secondary.opacity(0.12))
                    .frame(width: 80, height: 80)

                Image(systemName: "power")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(pm.isRunning ? .green : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status Block

    private var statusBlock: some View {
        VStack(spacing: 4) {
            Text(pm.isRunning ? "Connected" : "Disconnected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(pm.isRunning ? .green : .secondary)

            if let connectedAt, pm.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(uptimeString(from: connectedAt))
                        .font(.system(size: 20, weight: .light, design: .monospaced))
                        .monospacedDigit()
                }
            }

            if pm.isRunning {
                Text(loc.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let server = selectedServer {
                Text(server.name)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Setup Banner

    private var setupBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("Dependencies missing — check Settings")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack {
            VStack(spacing: 2) {
                Text(net.downloadSpeed)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.blue)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: net.downloadSpeed)
                Text("Download")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(net.uploadSpeed)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: net.uploadSpeed)
                Text("Upload")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pm.logs.suffix(30).reversed().enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 0.5)
                            .id(i)
                    }
                }
                .padding(6)
            }
            .frame(height: 80)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: - Helpers

    private func uptimeString(from date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - Sparkline (moved from DashboardView)

struct SparklineView: View {
    let downloadData: [Double]
    let uploadData: [Double]

    var body: some View {
        Canvas { context, size in
            drawLine(context: context, size: size, data: downloadData, color: .blue)
            drawLine(context: context, size: size, data: uploadData, color: .orange.opacity(0.6))
        }
        .frame(height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
    }

    private func drawLine(context: GraphicsContext, size: CGSize, data: [Double], color: Color) {
        let maxVal = max(data.max() ?? 1, 1)
        let stepX = size.width / CGFloat(data.count - 1)
        var path = Path()
        for (i, val) in data.enumerated() {
            let x = CGFloat(i) * stepX
            let y = size.height - (CGFloat(val / maxVal) * size.height * 0.9)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }
}

// MARK: - Subscription Group

private struct SubscriptionGroupView: View {
    let sub: Subscription
    @Binding var selectedServerID: String
    var onRefresh: () -> Void
    var onDelete: () -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { withAnimation { isExpanded.toggle() } } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                Text(sub.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Spacer()

                if !sub.isManual {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Menu {
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.06))

            if isExpanded {
                ForEach(sub.servers) { server in
                    ServerRow(server: server, isSelected: selectedServerID == server.id.uuidString)
                        .onTapGesture { selectedServerID = server.id.uuidString }
                }
            }
        }
    }
}

// MARK: - Server Row

private struct ServerRow: View {
    let server: Server
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(server.protocolType.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
    }
}

// MARK: - Add Subscription Sheet

private struct AddSubscriptionSheet: View {
    var subs: SubscriptionService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var engine: Engine = .singBox
    @State private var isManual = false
    @State private var manualJSON = ""
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Subscription")
                .font(.headline)

            Picker("Type", selection: $isManual) {
                Text("URL").tag(false)
                Text("Manual JSON").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Engine", selection: $engine) {
                ForEach(Engine.allCases, id: \.self) { e in
                    Text(e.rawValue).tag(e)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            if isManual {
                TextEditor(text: $manualJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 150)
                    .border(Color.secondary.opacity(0.3))
            } else {
                TextField("https://example.com/sub/token", text: $url)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { addSubscription() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || (isManual ? manualJSON.isEmpty : url.isEmpty))
            }

            if isLoading {
                ProgressView("Fetching servers...")
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func addSubscription() {
        if isManual {
            subs.addManualConfig(name: name, json: manualJSON, engine: engine)
            dismiss()
        } else {
            isLoading = true
            var sub = Subscription(name: name, url: url, engine: engine)
            subs.addSubscription(sub)
            Task {
                await subs.refreshSubscription(sub.id)
                isLoading = false
                dismiss()
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `Cmd+B` in Xcode
Expected: BUILD SUCCEEDED (or errors from ContentView not yet updated — fixed in Task 7)

- [ ] **Step 3: Commit**

```bash
git add Sources/ServersView.swift
git commit -m "feat: add ServersView with two-column server browser and connection panel"
```

---

### Task 6: Update SettingsView — Absorb Routing + Setup

**Files:**
- Modify: `Sources/SettingsView.swift`

- [ ] **Step 1: Rewrite SettingsView to include Routing and Setup sections**

Replace the entire contents of `Sources/SettingsView.swift` with:

```swift
import SwiftUI

struct SettingsView: View {
    var pm: ProcessManager
    var setup: SetupService

    @AppStorage("xrayPath") private var xrayPath = ""
    @AppStorage("singBoxPath") private var singBoxPath = ""
    @AppStorage("bypassDomains") private var bypassDomainsRaw = ""
    @AppStorage("bypassEnabled") private var bypassEnabled = true
    @State private var newDomain = ""

    private var bypassDomains: [String] {
        bypassDomainsRaw.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Form {
                    binaryPathsSection
                    passwordlessSection
                    bypassSection
                    dependenciesSection
                }
                .formStyle(.grouped)
            }

            HStack {
                Spacer()
                Button("Quit WarpVeil") {
                    if pm.isRunning { pm.disconnect() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApplication.shared.terminate(nil)
                    }
                }
                .keyboardShortcut("q")
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Binary Paths

    private var binaryPathsSection: some View {
        Section("Binary Paths") {
            LabeledContent("sing-box") {
                TextField("path", text: $singBoxPath)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("xray") {
                TextField("path", text: $xrayPath)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Passwordless

    private var passwordlessSection: some View {
        Section("Passwordless Mode") {
            HStack {
                if pm.isPasswordless {
                    Label("Enabled", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Disable") { pm.removePasswordless() }
                        .controlSize(.small)
                } else {
                    Label("Disabled", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Enable") { pm.installPasswordless() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Bypass Routing

    private var bypassSection: some View {
        Section("Domain Bypass") {
            Toggle("Enable domain bypass", isOn: $bypassEnabled)
                .controlSize(.small)

            HStack(spacing: 6) {
                TextField("example.com", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { addDomain() }
                Button("Add") { addDomain() }
                    .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                    .controlSize(.small)
            }

            if !bypassDomains.isEmpty {
                ForEach(bypassDomains, id: \.self) { domain in
                    HStack {
                        Text(domain)
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button {
                            removeDomain(domain)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onChange(of: bypassDomainsRaw) {
            guard pm.isRunning else { return }
            pm.reconnect(bypassDomains: bypassEnabled ? bypassDomains : [])
        }
        .onChange(of: bypassEnabled) {
            guard pm.isRunning else { return }
            pm.reconnect(bypassDomains: bypassEnabled ? bypassDomains : [])
        }
    }

    // MARK: - Dependencies

    private var dependenciesSection: some View {
        Section("Dependencies") {
            ForEach(Dependency.allCases) { dep in
                HStack {
                    depStatusIcon(setup.statuses[dep] ?? .unknown)
                    Text(dep.rawValue)
                        .font(.system(.body, weight: .medium))
                    Spacer()
                    depStatusLabel(setup.statuses[dep] ?? .unknown)
                }
            }

            HStack {
                Button("Check Again") { setup.checkAll() }
                    .controlSize(.small)
                    .disabled(setup.isInstalling)
                Spacer()
                if setup.allInstalled {
                    Label("All installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Button("Install Missing") { setup.installAll() }
                        .buttonStyle(.borderedProminent)
                        .disabled(setup.isInstalling || !setup.hasMissing)
                }
            }
        }
    }

    // MARK: - Helpers

    private func addDomain() {
        let domain = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        guard !domain.isEmpty, !bypassDomains.contains(domain) else { return }
        bypassDomainsRaw += (bypassDomainsRaw.isEmpty ? "" : "\n") + domain
        newDomain = ""
    }

    private func removeDomain(_ domain: String) {
        bypassDomainsRaw = bypassDomains.filter { $0 != domain }.joined(separator: "\n")
    }

    @ViewBuilder
    private func depStatusIcon(_ status: DependencyStatus) -> some View {
        switch status {
        case .unknown, .checking:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .installing:
            ProgressView().scaleEffect(0.5)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func depStatusLabel(_ status: DependencyStatus) -> some View {
        switch status {
        case .unknown:
            Text("Not checked").font(.caption).foregroundStyle(.secondary)
        case .checking:
            Text("Checking...").font(.caption).foregroundStyle(.secondary)
        case .installed(let path):
            Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        case .missing:
            Text("Not found").font(.caption).foregroundStyle(.red)
        case .installing:
            Text("Installing...").font(.caption).foregroundStyle(.blue)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.orange).lineLimit(1)
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `Cmd+B` in Xcode
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/SettingsView.swift
git commit -m "refactor: absorb routing and setup sections into SettingsView"
```

---

### Task 7: Update ContentView — 2 Tabs + New Wiring

**Files:**
- Modify: `Sources/ContentView.swift`

- [ ] **Step 1: Rewrite ContentView with 2 tabs and SubscriptionService integration**

Replace the entire contents of `Sources/ContentView.swift` with:

```swift
import SwiftUI

enum Tab: String, CaseIterable {
    case servers = "Servers"
    case settings = "Settings"
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
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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
        .background(.ultraThinMaterial)
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

    // MARK: - Actions

    private func doConnect() {
        guard let server = selectedServer,
              let sub = selectedSubscription else {
            pm.logs.append("[Error: no server selected]")
            return
        }

        let binaryPath: String
        switch sub.engine {
        case .singBox: binaryPath = singBoxPath
        case .xray: binaryPath = xrayPath
        }

        pm.connect(
            config: server.config,
            engine: sub.engine,
            binaryPath: binaryPath,
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
```

- [ ] **Step 2: Build to verify compilation**

Run: `Cmd+B` in Xcode
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/ContentView.swift
git commit -m "refactor: switch to 2-tab layout with subscription-based server selection"
```

---

### Task 8: Update WarpVeilApp — Init SubscriptionService + Window Size

**Files:**
- Modify: `Sources/WarpVeilApp.swift`

- [ ] **Step 1: Add SubscriptionService and update window size**

Replace the entire contents of `Sources/WarpVeilApp.swift` with:

```swift
import SwiftUI

@main
struct WarpVeilApp: App {
    @State private var pm = ProcessManager()
    @State private var loc = LocationService()
    @State private var net = NetworkMonitor()
    @State private var setup = SetupService()
    @State private var subs = SubscriptionService()

    var body: some Scene {
        MenuBarExtra {
            ContentView(pm: pm, loc: loc, net: net, setup: setup, subs: subs)
                .frame(width: 600, height: 500)
        } label: {
            Image(systemName: pm.isRunning ? "checkmark.shield.fill" : "shield.slash")
                .symbolEffect(.bounce, value: pm.isRunning)
            if pm.isRunning {
                Text(loc.flag)
                Image(systemName: net.hasTraffic ? "arrow.down.arrow.up.circle.fill" : "arrow.down.arrow.up.circle")
            } else if !loc.flag.isEmpty {
                Text(loc.flag)
            }
        }
        .menuBarExtraStyle(.window)
        .onChange(of: pm.isRunning) {
            if pm.isRunning {
                net.start()
            } else {
                net.stop()
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `Cmd+B` in Xcode
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/WarpVeilApp.swift
git commit -m "feat: init SubscriptionService and widen window to 600x500"
```

---

### Task 9: Delete Old Views

**Files:**
- Delete: `Sources/DashboardView.swift`
- Delete: `Sources/RoutingView.swift`

- [ ] **Step 1: Remove DashboardView.swift and RoutingView.swift**

```bash
git rm Sources/DashboardView.swift Sources/RoutingView.swift
```

- [ ] **Step 2: Build to verify no references remain**

Run: `Cmd+B` in Xcode
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: remove DashboardView and RoutingView, replaced by ServersView and SettingsView"
```

---

### Task 10: Add HTTP Exception for Subscription URLs

**Files:**
- Modify: `WarpVeil/Info.plist` (or wherever NSAppTransportSecurity is configured)

- [ ] **Step 1: Check current ATS config**

The app already has an HTTP exception for `ip-api.com`. Subscription URLs may also be HTTP (like the user's `http://83.217.213.48:2096`). Add `NSAllowsArbitraryLoads = true` to allow any HTTP URL for subscriptions, since users may have panels on non-HTTPS addresses.

In `Info.plist`, under `NSAppTransportSecurity`, set:
```xml
<key>NSAllowsArbitraryLoads</key>
<true/>
```

This replaces the domain-specific exception since subscription URLs can be any host.

- [ ] **Step 2: Build and run to verify**

Run: `Cmd+R` in Xcode
Expected: App launches, can fetch HTTP URLs

- [ ] **Step 3: Commit**

```bash
git add WarpVeil/Info.plist
git commit -m "feat: allow arbitrary HTTP loads for subscription URLs"
```

---

### Task 11: End-to-End Smoke Test

- [ ] **Step 1: Launch app, verify 2-tab layout appears**

Run: `Cmd+R` in Xcode
Expected: Menu bar icon appears, clicking shows popup with "Servers" and "Settings" tabs, window is ~600×500

- [ ] **Step 2: Add a URL subscription**

Click "+", enter a subscription URL and name, select engine, click "Add".
Expected: Servers appear in the left column grouped under the subscription name.

- [ ] **Step 3: Add a manual JSON subscription**

Click "+", switch to "Manual JSON", paste a sing-box config, click "Add".
Expected: Server(s) appear as a new group in the list.

- [ ] **Step 4: Select server and connect**

Click a server in the list, click the power button.
Expected: VPN connects, status changes to "Connected", uptime timer starts, traffic stats appear.

- [ ] **Step 5: Verify Settings tab**

Switch to Settings tab.
Expected: Binary paths, passwordless mode, domain bypass, and dependencies sections all visible and functional.

- [ ] **Step 6: Disconnect and verify cleanup**

Click power button again.
Expected: VPN disconnects, status returns to "Disconnected".
