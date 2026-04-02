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
