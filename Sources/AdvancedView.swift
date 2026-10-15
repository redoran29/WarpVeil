import SwiftUI

struct AdvancedView: View {
    var app: AppState

    @AppStorage("autoConnect") private var autoConnect = false

    var body: some View {
        Form {
            Section("Connection") {
                Toggle(isOn: $autoConnect) {
                    Text("Auto-connect")
                    Text("Connect on app launch")
                }

                // Installed by the connect that needs it; the row only says so and takes it away.
                LabeledContent {
                    if app.pm.isPasswordless {
                        Button("Remove") { app.pm.removePasswordless() }
                            .disabled(!app.pm.canRemoveHelper)
                    }
                } label: {
                    Text("Helper")
                    Text(helperStatus)
                }
                .disabled(app.pm.isPasswordlessBusy)
                // Another build's install removes this one's helper without this page knowing.
                .onAppear { app.pm.refreshPasswordless() }
            }

            Section("Components") {
                ForEach(Dependency.allCases) { dep in
                    LabeledContent {
                        if let version = app.setup.versions[dep] {
                            Text(version)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            depStatusLabel(app.setup.statuses[dep] ?? .unknown)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            depStatusIcon(app.setup.statuses[dep] ?? .unknown)
                            Text(dep.rawValue)
                        }
                    }
                }
            }

            Section("Updates") {
                LabeledContent {
                    if app.updater.availableVersion != nil {
                        Button("Install") { app.installUpdate() }
                    } else {
                        Button("Check for Updates") { Task { await app.updater.check(manual: true) } }
                    }
                } label: {
                    Text("WarpVeil \(Updater.currentVersion)")
                    Text(updateStatus)
                }
                .disabled(app.updater.state == .checking || app.updater.state == .installing)
            }
        }
        .formStyle(.grouped)
    }

    private var updateStatus: String {
        switch app.updater.state {
        case .idle: "Checked once a day"
        case .checking: "Checking..."
        case .upToDate: "Up to date"
        case .available(let version): "Version \(version) is available"
        case .installing: "Downloading and installing — the app relaunches when done"
        case .failed(let reason): reason
        }
    }

    private var helperStatus: String {
        if app.pm.isPasswordlessBusy { return "Waiting for admin prompt..." }
        return app.pm.isPasswordless
            ? "Starts the engine without a password"
            : "The next connect installs it, with your password once"
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
        }
    }

    @ViewBuilder
    private func depStatusLabel(_ status: DependencyStatus) -> some View {
        switch status {
        case .unknown:
            Text("Not checked").font(.system(size: 11)).foregroundStyle(.secondary)
        case .checking:
            Text("Checking...").font(.system(size: 11)).foregroundStyle(.secondary)
        case .installed(let path):
            let label = path.hasPrefix(Bundle.main.resourcePath ?? "") ? "Bundled" : path
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        case .missing:
            Text("Not found").font(.system(size: 11)).foregroundStyle(.red)
        }
    }
}
