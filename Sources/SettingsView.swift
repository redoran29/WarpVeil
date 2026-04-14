import SwiftUI

struct SettingsView: View {
    var pm: ProcessManager
    var setup: SetupService

    @AppStorage("autoConnect") private var autoConnect = false
    @AppStorage("killSwitch") private var killSwitch = false
    @AppStorage("bypassDomains") private var bypassDomainsRaw = ""
    @AppStorage("bypassEnabled") private var bypassEnabled = true
    @State private var newDomain = ""
    @State private var showNewDomainField = false

    private var bypassDomains: [String] {
        bypassDomainsRaw.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                connectionSection
                bypassSection
                componentsSection
            }
            .padding(.vertical, 8)
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

    // MARK: - Connection Section

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("ПОДКЛЮЧЕНИЕ")

            settingsToggle(
                title: "Автоподключение",
                subtitle: "При запуске приложения",
                isOn: $autoConnect
            )

            settingsDivider

            settingsToggle(
                title: "Без пароля",
                subtitle: "Passwordless mode",
                isOn: Binding(
                    get: { pm.isPasswordless },
                    set: { newValue in
                        if newValue { pm.installPasswordless() }
                        else { pm.removePasswordless() }
                    }
                )
            )

            settingsDivider

            settingsToggle(
                title: "Kill Switch",
                subtitle: "Блокировать трафик при разрыве",
                isOn: $killSwitch
            )
        }
    }

    // MARK: - Bypass Section

    private var bypassSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("ОБХОД ДОМЕНА")

            settingsToggle(
                title: "Включить обход",
                subtitle: nil,
                isOn: $bypassEnabled
            )

            if bypassEnabled {
                ForEach(bypassDomains, id: \.self) { domain in
                    domainRow(domain)
                }

                if showNewDomainField {
                    HStack(spacing: 8) {
                        TextField("example.com", text: $newDomain)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .onSubmit { addDomain() }
                        Button("OK") { addDomain() }
                            .font(.system(size: 11))
                            .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button {
                            showNewDomainField = false
                            newDomain = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                } else {
                    Button("+ Добавить домен") {
                        showNewDomainField = true
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.indigo)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Components Section

    private var componentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("КОМПОНЕНТЫ")

            ForEach(Dependency.allCases) { dep in
                HStack(spacing: 10) {
                    depStatusIcon(setup.statuses[dep] ?? .unknown)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dep.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        depStatusLabel(setup.statuses[dep] ?? .unknown)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            HStack {
                Button("Проверить") { setup.checkAll() }
                    .font(.system(size: 12))
                    .disabled(setup.isInstalling)

                Spacer()

                if setup.allInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Установлено")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                } else {
                    Button("Установить") { setup.installAll() }
                        .font(.system(size: 12))
                        .disabled(setup.isInstalling || !setup.hasMissing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Reusable Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .tracking(1)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .padding(.top, 4)
    }

    private func settingsToggle(title: String, subtitle: String?, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(Color(red: 0.62, green: 0.56, blue: 0.85))
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var settingsDivider: some View {
        Divider()
            .padding(.leading, 16)
    }

    private func domainRow(_ domain: String) -> some View {
        HStack {
            Text(domain)
                .font(.system(size: 13, design: .monospaced))
            Spacer()
            Button {
                removeDomain(domain)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func addDomain() {
        let domain = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        guard !domain.isEmpty, !bypassDomains.contains(domain) else { return }
        bypassDomainsRaw += (bypassDomainsRaw.isEmpty ? "" : "\n") + domain
        newDomain = ""
        showNewDomainField = false
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
            Text("Не проверено").font(.system(size: 10)).foregroundStyle(.secondary)
        case .checking:
            Text("Проверка...").font(.system(size: 10)).foregroundStyle(.secondary)
        case .installed(let path):
            Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        case .missing:
            Text("Не найдено").font(.system(size: 10)).foregroundStyle(.red)
        case .installing:
            Text("Установка...").font(.system(size: 10)).foregroundStyle(.blue)
        case .failed(let msg):
            Text(msg).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
        }
    }
}
