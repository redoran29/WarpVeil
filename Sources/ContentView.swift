import SwiftUI

enum Tab: String, CaseIterable {
    case dashboard = "Dashboard"
    case setup = "Setup"
    case settings = "Settings"
}

struct ContentView: View {
    var pm: ProcessManager
    var loc: LocationService
    var net: NetworkMonitor
    var setup: SetupService

    @State private var tab: Tab = .dashboard
    @State private var locationTimer: Timer?
    @State private var connectedAt: Date?
    @AppStorage("xrayConfig") private var xrayConfig = ""
    @AppStorage("singBoxConfig") private var singBoxConfig = ""
    @AppStorage("xrayPath") private var xrayPath = ""
    @AppStorage("singBoxPath") private var singBoxPath = ""

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t.rawValue)
                        .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? .primary : .secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { tab = t }
                        .background(tab == t ? Color.accentColor.opacity(0.12) : .clear)
                }
            }
            .frame(height: 32)
            .background(.bar)

            Divider()

            switch tab {
            case .dashboard: dashboardTab
            case .setup: setupTab
            case .settings: settingsTab
            }
        }
        .task {
            await loc.detect()
            setup.checkAll()
            if singBoxPath.isEmpty || !FileManager.default.isExecutableFile(atPath: singBoxPath) {
                singBoxPath = ProcessManager.findBinary("sing-box") ?? ""
            }
            if xrayPath.isEmpty || !FileManager.default.isExecutableFile(atPath: xrayPath) {
                xrayPath = ProcessManager.findBinary("xray") ?? ""
            }
            pm.onReconnect = { [self] in
                connectedAt = Date()
                startLocationTimer()
            }
        }
        .onChange(of: setup.singBoxPath) { _, newPath in
            if let newPath, !newPath.isEmpty { singBoxPath = newPath }
        }
        .onChange(of: setup.xrayPath) { _, newPath in
            if let newPath, !newPath.isEmpty { xrayPath = newPath }
        }
    }

    // MARK: - Dashboard

    private var dashboardTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc.ip).font(.system(.body, design: .monospaced))
                    Text(loc.location).font(.caption).foregroundStyle(.secondary)
                }
                if loc.isLoading { ProgressView().scaleEffect(0.6) }
                Button { Task { await loc.detect() } } label: {
                    Image(systemName: "arrow.clockwise")
                }

                Spacer()

                Button {
                    if pm.isRunning {
                        doDisconnect()
                    } else {
                        doConnect()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(pm.isRunning ? .green : .gray).frame(width: 7, height: 7)
                        Text(pm.isRunning ? "Disconnect" : "Connect")
                    }
                    .frame(width: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(pm.isRunning ? .red : .green)
            }
            .padding(10)

            // Stats bar (when connected)
            if pm.isRunning {
                Divider()
                HStack(spacing: 16) {
                    Label("↓ \(net.downloadSpeed)", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Label("↑ \(net.uploadSpeed)", systemImage: "arrow.up.circle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    if let connectedAt {
                        Label(uptimeString(from: connectedAt), systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.bar)
            }

            Divider()

            // Unified log
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Log").font(.caption).fontWeight(.medium)
                    Spacer()
                    Button("Clear") { pm.clearLogs() }.controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(pm.logs.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 0.5)
                                    .id(i)
                            }
                        }
                        .padding(6)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: pm.logs.count) {
                        if let last = pm.logs.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Setup

    private var setupTab: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                ForEach(Dependency.allCases) { dep in
                    HStack {
                        depStatusIcon(setup.statuses[dep] ?? .unknown)
                        Text(dep.rawValue)
                            .font(.system(.body, weight: .medium))
                        Spacer()
                        depStatusLabel(setup.statuses[dep] ?? .unknown)
                    }
                }
            }
            .padding(12)

            Divider()

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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Installation Log").font(.caption).fontWeight(.medium)
                    Spacer()
                    if setup.isInstalling { ProgressView().scaleEffect(0.6) }
                    Button("Clear") { setup.logs.removeAll() }.controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(setup.logs.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 0.5)
                                    .id(i)
                            }
                        }
                        .padding(6)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: setup.logs.count) {
                        if let last = setup.logs.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
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

    // MARK: - Settings

    private var settingsTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("sing-box:").font(.caption).foregroundStyle(.secondary)
                    TextField("path to sing-box", text: $singBoxPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                HStack(spacing: 6) {
                    Text("xray:").font(.caption).foregroundStyle(.secondary)
                    TextField("path to xray", text: $xrayPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .padding(10)

            Divider()

            HStack {
                if pm.isPasswordless {
                    Label("Passwordless mode", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Disable") { pm.removePasswordless() }
                        .controlSize(.small)
                } else {
                    Label("Passwordless mode", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Enable") { pm.installPasswordless() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            HStack(spacing: 0) {
                configEditor("sing-box Config", text: $singBoxConfig)
                Divider()
                configEditor("Xray Config", text: $xrayConfig)
            }
        }
    }

    private func configEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.top, 6)
            TextEditor(text: text)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func doConnect() {
        pm.connect(
            singBoxPath: singBoxPath, singBoxConfig: singBoxConfig,
            xrayPath: xrayPath, xrayConfig: xrayConfig
        )
        connectedAt = Date()
        startLocationTimer()
    }

    private func doDisconnect() {
        pm.disconnect()
        connectedAt = nil
        locationTimer?.invalidate()
        locationTimer = nil
        // Refresh location with retry at 3, 5, 10 seconds (same as connect)
        Task {
            for delay in [3, 5, 10] {
                try? await Task.sleep(for: .seconds(delay))
                let oldIP = loc.ip
                await loc.detect()
                if loc.ip != oldIP { break }
            }
        }
    }

    private func uptimeString(from date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    private func startLocationTimer() {
        locationTimer?.invalidate()
        // Retry a few times — TUN needs time to start routing
        Task {
            for delay in [3, 5, 10] {
                try? await Task.sleep(for: .seconds(delay))
                let oldIP = loc.ip
                await loc.detect()
                if loc.ip != oldIP { break } // IP changed, tunnel is working
            }
        }
        locationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { await loc.detect() }
        }
    }
}
