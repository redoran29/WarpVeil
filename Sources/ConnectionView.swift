import SwiftUI

struct ConnectionView: View {
    var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            powerButton
                .padding(.bottom, 10)

            statusSection
                .padding(.bottom, 16)

            if app.pm.isTunnelUp {
                statsSection
                    .frame(maxWidth: 360)
                    .padding(.bottom, 20)
            }

            locationSection
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // This column is on every page, so a new version is seen without opening Advanced.
        .safeAreaInset(edge: .bottom) {
            if let version = app.updater.newerVersion {
                updateBanner(version: version)
                    .frame(maxWidth: 360)
                    .padding([.horizontal, .bottom], 20)
            }
        }
    }

    // MARK: - Update

    private func updateBanner(version: String) -> some View {
        let state = app.updater.state
        let isInstalling = state == .installing
        return HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.lavender)
            VStack(alignment: .leading, spacing: 2) {
                Text(isInstalling ? "Installing WarpVeil \(version)…" : "WarpVeil \(version) is available")
                    .font(.system(size: 13, weight: .medium))
                // A failed install says why here too, or the banner would only lose its button.
                Text(state == .available(version) ? "You have \(Updater.currentVersion)" : app.updater.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !isInstalling {
                // Not during a check: its answer would be dropped for the release known before it.
                Button("Install") { app.installUpdate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state == .checking)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.lavender.opacity(0.12)))
    }

    // MARK: - Power Button

    private var powerButton: some View {
        Button {
            if app.pm.isRunning { app.disconnect() } else { app.connect() }
        } label: {
            ZStack {
                Circle()
                    .fill(app.pm.isRunning ? Color.lavender.opacity(0.12) : Color.secondary.opacity(0.05))
                    .frame(width: 130, height: 130)

                Circle()
                    .fill(app.pm.isRunning ? Color.lavender.opacity(0.2) : Color.secondary.opacity(0.08))
                    .frame(width: 108, height: 108)

                Circle()
                    .stroke(app.pm.isRunning ? Color.lavender.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: 1.5)
                    .frame(width: 108, height: 108)

                Image(systemName: "power")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(app.pm.isRunning ? Color.lavender : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!app.pm.isRunning && app.selectedServer == nil)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(spacing: 4) {
            Text(app.pm.isTunnelUp ? "Connected" : app.pm.isRunning ? "Connecting…" : "Disconnected")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(app.pm.isTunnelUp ? .green : .secondary)

            // In its own column the button no longer sits under the list, so it has to say
            // what it would connect to.
            Text(app.selectedServer?.name ?? "No server selected")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let connectedAt = app.connectedAt, app.pm.isTunnelUp {
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
                .multilineTextAlignment(.center)
                .lineLimit(3)
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
