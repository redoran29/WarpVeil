import SwiftUI

struct ConnectionView: View {
    var app: AppState

    @AppStorage("selectedServerID") private var selectedServerID = ""

    private let lavender = Color(red: 0.62, green: 0.56, blue: 0.85)

    private var allServers: [Server] {
        app.subs.subscriptions.flatMap(\.servers)
    }

    var body: some View {
        VStack(spacing: 0) {
            powerButton
                .padding(.top, 28)
                .padding(.bottom, 10)

            statusSection
                .padding(.bottom, 16)

            if app.pm.isRunning {
                statsSection
                    .frame(maxWidth: 360)
                    .padding(.bottom, 20)
            }

            locationSection
                .padding(.bottom, 20)

            serverPicker
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
    }

    // MARK: - Power Button

    private var powerButton: some View {
        Button {
            if app.pm.isRunning { app.disconnect() } else { app.connect() }
        } label: {
            ZStack {
                Circle()
                    .fill(app.pm.isRunning ? lavender.opacity(0.12) : Color.secondary.opacity(0.05))
                    .frame(width: 130, height: 130)

                Circle()
                    .fill(app.pm.isRunning ? lavender.opacity(0.2) : Color.secondary.opacity(0.08))
                    .frame(width: 108, height: 108)

                Circle()
                    .stroke(app.pm.isRunning ? lavender.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: 1.5)
                    .frame(width: 108, height: 108)

                Image(systemName: "power")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(app.pm.isRunning ? lavender : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(spacing: 4) {
            Text(app.pm.isRunning ? "Connected" : "Disconnected")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(app.pm.isRunning ? .green : .secondary)

            if let connectedAt = app.connectedAt, app.pm.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(uptimeString(from: connectedAt))
                        .font(.system(size: 30, weight: .light, design: .monospaced))
                        .monospacedDigit()
                }
            }
        }
    }

    private var locationSection: some View {
        VStack(spacing: 2) {
            Text(app.loc.ip)
                .font(.system(size: 12, design: .monospaced))
            Text(app.loc.location)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Server

    @ViewBuilder
    private var serverPicker: some View {
        if allServers.isEmpty {
            Text("No servers — add one on the Servers page")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            Picker("Server", selection: $selectedServerID) {
                ForEach(allServers) { server in
                    Text(server.name).tag(server.id.uuidString)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 12) {
            statBox(label: "DOWNLOAD", icon: "arrow.down", bps: app.net.downloadBPS)
            statBox(label: "UPLOAD", icon: "arrow.up", bps: app.net.uploadBPS)
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

    private func uptimeString(from date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
