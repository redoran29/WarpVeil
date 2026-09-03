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

                Toggle(isOn: Binding(
                    get: { app.pm.isPasswordless },
                    set: { $0 ? app.pm.installPasswordless() : app.pm.removePasswordless() }
                )) {
                    Text("Passwordless")
                    Text(app.pm.isPasswordlessBusy ? "Waiting for admin prompt..." : "Skip password prompts via sudoers")
                }
                .disabled(app.pm.isPasswordlessBusy)
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
        }
        .formStyle(.grouped)
        .frame(maxHeight: 520)
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
