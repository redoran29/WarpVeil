import SwiftUI
import Network

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
    @State private var showLog = false
    @State private var pings: [UUID: Int] = [:]

    private var allServers: [Server] {
        subs.subscriptions.flatMap(\.servers)
    }

    var selectedServer: Server? {
        allServers.first { $0.id.uuidString == selectedServerID }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        powerButton
                            .padding(.top, 28)
                            .padding(.bottom, 10)

                        statusSection
                            .padding(.bottom, 16)

                        if pm.isRunning {
                            statsSection
                                .padding(.horizontal, 20)
                                .padding(.bottom, 20)
                        }

                        if !setup.allInstalled {
                            setupBanner
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }

                        serverListSection
                            .padding(.bottom, 12)
                    }
                }

                Divider()
                bottomBar
            }

            if showLog {
                logOverlay
            }

            if showAddSheet {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .onTapGesture { showAddSheet = false }
                AddSubscriptionSheet(subs: subs, isPresented: $showAddSheet)
                    .frame(maxWidth: 340)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showAddSheet)
        .animation(.easeInOut(duration: 0.2), value: showLog)
        .task {
            await measurePings()
        }
    }

    // MARK: - Power Button

    private let lavender = Color(red: 0.62, green: 0.56, blue: 0.85)

    private var powerButton: some View {
        Button {
            if pm.isRunning { onDisconnect() } else { onConnect() }
        } label: {
            ZStack {
                Circle()
                    .fill(pm.isRunning ? lavender.opacity(0.12) : Color.secondary.opacity(0.05))
                    .frame(width: 130, height: 130)

                Circle()
                    .fill(pm.isRunning ? lavender.opacity(0.2) : Color.secondary.opacity(0.08))
                    .frame(width: 108, height: 108)

                Circle()
                    .stroke(pm.isRunning ? lavender.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: 1.5)
                    .frame(width: 108, height: 108)

                Image(systemName: "power")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(pm.isRunning ? lavender : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(spacing: 4) {
            Text(pm.isRunning ? "Connected" : "Disconnected")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(pm.isRunning ? .green : .secondary)

            if let connectedAt, pm.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(uptimeString(from: connectedAt))
                        .font(.system(size: 30, weight: .light, design: .monospaced))
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 12) {
            statBox(label: "DOWNLOAD", icon: "arrow.down", bps: net.downloadBPS)
            statBox(label: "UPLOAD", icon: "arrow.up", bps: net.uploadBPS)
        }
    }

    private func statBox(label: String, icon: String, bps: Double) -> some View {
        let (value, unit) = NetworkMonitor.formatSplit(bps)
        return VStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Server List

    private var serverListSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SERVERS")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                Spacer()
                Button("+ Add") { showAddSheet = true }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.indigo)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            if allServers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text("No servers")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Button("Add subscription") { showAddSheet = true }
                        .font(.system(size: 12))
                        .foregroundStyle(.indigo)
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 2) {
                    ForEach(allServers) { server in
                        ServerRowView(
                            server: server,
                            isSelected: selectedServerID == server.id.uuidString,
                            ping: pings[server.id]
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { selectedServerID = server.id.uuidString }
                        .contextMenu {
                            if let sub = subscriptionFor(server) {
                                if !sub.isManual {
                                    Button("Refresh subscription") {
                                        Task { await subs.refreshSubscription(sub.id) }
                                    }
                                }
                                Button("Delete subscription", role: .destructive) {
                                    subs.removeSubscription(sub.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - Setup Banner

    private var setupBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text("Dependencies missing — check Settings")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            HStack(spacing: 0) {
                Text("IP:")
                    .foregroundStyle(.secondary)
                Text(" \(loc.ip)")
            }
            .font(.system(size: 12, design: .monospaced))

            Spacer()

            Button {
                showLog = true
            } label: {
                HStack(spacing: 3) {
                    Text("Show log")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .medium))
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.indigo)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Log Overlay

    private var logOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    let text = pm.logs.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy")

                Button {
                    pm.clearLogs()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear")

                Button { showLog = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pm.logs.reversed().enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 0.5)
                    }
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Ping

    private func measurePings() async {
        for server in allServers {
            let parts = server.address.split(separator: ":")
            guard let host = parts.first, !host.isEmpty, host != "?" else { continue }
            let port = parts.count > 1 ? UInt16(parts[1]) ?? 443 : 443

            if let ms = await tcpPing(host: String(host), port: port) {
                pings[server.id] = ms
            }
        }
    }

    private func tcpPing(host: String, port: UInt16) async -> Int? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let start = CFAbsoluteTimeGetCurrent()
            let resumed = NSLock()
            var didResume = false

            let complete: @Sendable (Int?) -> Void = { value in
                resumed.lock()
                guard !didResume else { resumed.unlock(); return }
                didResume = true
                resumed.unlock()
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    complete(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
                case .failed, .cancelled:
                    complete(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                complete(nil)
            }
        }
    }

    // MARK: - Helpers

    private func subscriptionFor(_ server: Server) -> Subscription? {
        subs.subscriptions.first { sub in
            sub.servers.contains { $0.id == server.id }
        }
    }

    private func uptimeString(from date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - Server Row

private struct ServerRowView: View {
    let server: Server
    let isSelected: Bool
    let ping: Int?

    private static let lavender = Color(red: 0.62, green: 0.56, blue: 0.85)

    var body: some View {
        HStack(spacing: 12) {
            Text(Self.guessFlag(from: server.name))
                .font(.system(size: 22))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(protocolLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let ping {
                Text("\(ping)ms")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(pingColor(ping))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Self.lavender.opacity(0.15) : .clear)
        )
    }

    private var protocolLabel: String {
        let proto = server.protocolType.uppercased()
        let transport = Self.detectTransport(from: server)
        return transport.isEmpty ? proto : "\(proto) \u{00B7} \(transport)"
    }

    private func pingColor(_ ms: Int) -> Color {
        if ms < 60 { return Color(red: 0.13, green: 0.55, blue: 0.22) }
        if ms < 150 { return .orange }
        return .red
    }

    private static func detectTransport(from server: Server) -> String {
        guard let data = server.config.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]]
        else { return "" }

        for ob in outbounds {
            if let transport = ob["transport"] as? [String: Any],
               let type = transport["type"] as? String {
                return type.uppercased()
            }
            if let stream = ob["streamSettings"] as? [String: Any],
               let network = stream["network"] as? String, network != "tcp" {
                return network.uppercased()
            }
        }
        return ""
    }

    private static func guessFlag(from name: String) -> String {
        let lower = name.lowercased()
        let map: [(String, String)] = [
            ("chicago", "\u{1F1FA}\u{1F1F8}"), ("new york", "\u{1F1FA}\u{1F1F8}"),
            ("los angeles", "\u{1F1FA}\u{1F1F8}"), ("dallas", "\u{1F1FA}\u{1F1F8}"),
            ("miami", "\u{1F1FA}\u{1F1F8}"), ("seattle", "\u{1F1FA}\u{1F1F8}"),
            ("san ", "\u{1F1FA}\u{1F1F8}"), ("washington", "\u{1F1FA}\u{1F1F8}"),
            ("us-", "\u{1F1FA}\u{1F1F8}"), ("usa", "\u{1F1FA}\u{1F1F8}"),
            ("frankfurt", "\u{1F1E9}\u{1F1EA}"), ("berlin", "\u{1F1E9}\u{1F1EA}"),
            ("munich", "\u{1F1E9}\u{1F1EA}"), ("de-", "\u{1F1E9}\u{1F1EA}"),
            ("amsterdam", "\u{1F1F3}\u{1F1F1}"), ("nl-", "\u{1F1F3}\u{1F1F1}"),
            ("london", "\u{1F1EC}\u{1F1E7}"), ("uk-", "\u{1F1EC}\u{1F1E7}"),
            ("paris", "\u{1F1EB}\u{1F1F7}"), ("fr-", "\u{1F1EB}\u{1F1F7}"),
            ("tokyo", "\u{1F1EF}\u{1F1F5}"), ("osaka", "\u{1F1EF}\u{1F1F5}"),
            ("jp-", "\u{1F1EF}\u{1F1F5}"),
            ("singapore", "\u{1F1F8}\u{1F1EC}"), ("sg-", "\u{1F1F8}\u{1F1EC}"),
            ("moscow", "\u{1F1F7}\u{1F1FA}"), ("ru-", "\u{1F1F7}\u{1F1FA}"),
            ("russia", "\u{1F1F7}\u{1F1FA}"),
            ("helsinki", "\u{1F1EB}\u{1F1EE}"), ("fi-", "\u{1F1EB}\u{1F1EE}"),
            ("stockholm", "\u{1F1F8}\u{1F1EA}"), ("se-", "\u{1F1F8}\u{1F1EA}"),
            ("toronto", "\u{1F1E8}\u{1F1E6}"), ("ca-", "\u{1F1E8}\u{1F1E6}"),
            ("sydney", "\u{1F1E6}\u{1F1FA}"), ("au-", "\u{1F1E6}\u{1F1FA}"),
            ("hong kong", "\u{1F1ED}\u{1F1F0}"), ("hk-", "\u{1F1ED}\u{1F1F0}"),
            ("istanbul", "\u{1F1F9}\u{1F1F7}"), ("tr-", "\u{1F1F9}\u{1F1F7}"),
            ("warsaw", "\u{1F1F5}\u{1F1F1}"), ("pl-", "\u{1F1F5}\u{1F1F1}"),
            ("bucharest", "\u{1F1F7}\u{1F1F4}"), ("ro-", "\u{1F1F7}\u{1F1F4}"),
            ("kyiv", "\u{1F1FA}\u{1F1E6}"), ("kiev", "\u{1F1FA}\u{1F1E6}"),
            ("ua-", "\u{1F1FA}\u{1F1E6}"),
            ("tallinn", "\u{1F1EA}\u{1F1EA}"), ("ee-", "\u{1F1EA}\u{1F1EA}"),
            ("riga", "\u{1F1F1}\u{1F1FB}"), ("lv-", "\u{1F1F1}\u{1F1FB}"),
            ("vilnius", "\u{1F1F1}\u{1F1F9}"), ("lt-", "\u{1F1F1}\u{1F1F9}"),
            ("sofia", "\u{1F1E7}\u{1F1EC}"), ("bg-", "\u{1F1E7}\u{1F1EC}"),
            ("prague", "\u{1F1E8}\u{1F1FF}"), ("cz-", "\u{1F1E8}\u{1F1FF}"),
            ("vienna", "\u{1F1E6}\u{1F1F9}"), ("at-", "\u{1F1E6}\u{1F1F9}"),
            ("zurich", "\u{1F1E8}\u{1F1ED}"), ("ch-", "\u{1F1E8}\u{1F1ED}"),
            ("madrid", "\u{1F1EA}\u{1F1F8}"), ("es-", "\u{1F1EA}\u{1F1F8}"),
            ("lisbon", "\u{1F1F5}\u{1F1F9}"), ("pt-", "\u{1F1F5}\u{1F1F9}"),
            ("milan", "\u{1F1EE}\u{1F1F9}"), ("rome", "\u{1F1EE}\u{1F1F9}"),
            ("it-", "\u{1F1EE}\u{1F1F9}"),
            ("seoul", "\u{1F1F0}\u{1F1F7}"), ("kr-", "\u{1F1F0}\u{1F1F7}"),
            ("mumbai", "\u{1F1EE}\u{1F1F3}"), ("in-", "\u{1F1EE}\u{1F1F3}"),
            ("sao paulo", "\u{1F1E7}\u{1F1F7}"), ("br-", "\u{1F1E7}\u{1F1F7}"),
        ]
        for (pattern, flag) in map {
            if lower.contains(pattern) { return flag }
        }
        return "\u{1F310}" // globe
    }
}

// MARK: - Add Subscription Sheet

private struct AddSubscriptionSheet: View {
    var subs: SubscriptionService
    @Binding var isPresented: Bool

    @State private var isManual = false
    @State private var url = ""
    @State private var manualName = ""
    @State private var manualJSON = ""
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Add Subscription")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Picker("", selection: $isManual) {
                Text("URL").tag(false)
                Text("JSON").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            if isManual {
                TextField("Name", text: $manualName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                TextEditor(text: $manualJSON)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
            } else {
                TextField("vless://... или URL подписки", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { addSubscription() }
            }

            HStack {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("Loading...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add") { addSubscription() }
                    .controlSize(.small)
                    .disabled(isManual ? (manualName.isEmpty || manualJSON.isEmpty) : url.isEmpty)
                    .disabled(isLoading)
            }
        }
        .padding(14)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 20)
    }

    private func addSubscription() {
        if isManual {
            subs.addManualConfig(name: manualName, json: manualJSON)
            isPresented = false
        } else {
            isLoading = true
            Task {
                await subs.addFromURL(url)
                isLoading = false
                isPresented = false
            }
        }
    }
}
