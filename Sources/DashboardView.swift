import SwiftUI

struct DashboardView: View {
    var pm: ProcessManager
    var loc: LocationService
    var net: NetworkMonitor
    var setup: SetupService
    @Binding var connectedAt: Date?
    var onConnect: () -> Void
    var onDisconnect: () -> Void

    @State private var logExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if !setup.allInstalled {
                setupBanner
            }

            heroBlock
                .padding(16)

            Divider()

            if pm.isRunning {
                statsRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
            }

            logSection

            Spacer(minLength: 0)
        }
    }

    // MARK: - Setup Banner

    private var setupBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Dependencies missing")
                .font(.caption)
            Spacer()
            Text("Go to Setup tab")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Hero Block

    private var heroBlock: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                StatusIndicator(isConnected: pm.isRunning)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pm.isRunning ? "Connected" : "Disconnected")
                        .font(.system(size: 15, weight: .semibold))
                    Text(loc.ip)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if loc.isLoading {
                    ProgressView().scaleEffect(0.6)
                }
                Button { Task { await loc.detect() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Text(loc.location)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if pm.isRunning { onDisconnect() } else { onConnect() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: pm.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 11))
                    Text(pm.isRunning ? "Disconnect" : "Connect")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(pm.isRunning ? .red : .accentColor)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(pm.isRunning ? Color.green.opacity(0.06) : Color.secondary.opacity(0.04))
        )
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack {
            statItem(value: net.downloadSpeed, label: "Download", icon: "arrow.down", color: .blue)
            Spacer()
            statItem(value: net.uploadSpeed, label: "Upload", icon: "arrow.up", color: .orange)
            Spacer()
            if let connectedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    statItem(value: uptimeString(from: connectedAt), label: "Uptime", icon: "clock", color: .secondary)
                }
            }
        }
    }

    private func statItem(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 80)
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { logExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: logExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text("Log")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("(\(pm.logs.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if logExpanded {
                        Button("Clear") { pm.clearLogs() }
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if logExpanded {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(pm.logs.reversed().enumerated()), id: \.offset) { i, line in
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
                    .background(Color(nsColor: .textBackgroundColor))
                    .frame(maxHeight: 200)
                    .onChange(of: pm.logs.count) {
                        proxy.scrollTo(0, anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func uptimeString(from date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }
}
