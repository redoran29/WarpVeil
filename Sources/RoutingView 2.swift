import SwiftUI

struct RoutingView: View {
    var pm: ProcessManager
    @AppStorage("bypassDomains") private var bypassDomainsRaw = ""
    @AppStorage("bypassEnabled") private var bypassEnabled = true
    @State private var newDomain = ""
    @State private var cachedBypassLines: [String] = []

    var bypassDomains: [String] {
        bypassDomainsRaw.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Domain bypass", isOn: $bypassEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Text("\(bypassDomains.count) domain(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 6) {
                TextField("example.com", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { addDomain() }
                Button("Add") { addDomain() }
                    .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if bypassDomains.isEmpty {
                ContentUnavailableView {
                    Label("No Bypass Domains", systemImage: "network.badge.shield.half.filled")
                } description: {
                    Text("Domains added here will route outside the VPN.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
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
                .listStyle(.bordered)
            }

            if pm.isRunning {
                Divider()
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.green)
                        .font(.caption2)
                    Text("Changes apply automatically")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Bypass Log").font(.caption).fontWeight(.medium)
                    Spacer()
                    Text("\(cachedBypassLines.count)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if cachedBypassLines.isEmpty {
                            Text(pm.isRunning ? "Waiting for bypass traffic..." : "Connect VPN to see bypass log")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(6)
                        } else {
                            ForEach(Array(cachedBypassLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 0.5)
                            }
                        }
                    }
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .frame(maxHeight: 120)
            }
        }
        .onChange(of: pm.logs.count) { updateBypassLogLines() }
        .onChange(of: bypassDomainsRaw) {
            updateBypassLogLines()
            guard pm.isRunning else { return }
            pm.reconnect(bypassDomains: bypassEnabled ? bypassDomains : [])
        }
        .onChange(of: bypassEnabled) {
            guard pm.isRunning else { return }
            pm.reconnect(bypassDomains: bypassEnabled ? bypassDomains : [])
        }
    }

    private func updateBypassLogLines() {
        let domains = bypassDomains
        guard !domains.isEmpty else { cachedBypassLines = []; return }
        cachedBypassLines = pm.logs.filter { line in
            let low = line.lowercased()
            if low.hasPrefix("[bypass]") { return true }
            return domains.contains(where: { low.contains($0) })
        }.reversed()
    }

    private func addDomain() {
        let domain = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        guard !domain.isEmpty, !bypassDomains.contains(domain) else { return }
        bypassDomainsRaw += (bypassDomainsRaw.isEmpty ? "" : "\n") + domain
        newDomain = ""
    }

    private func removeDomain(_ domain: String) {
        bypassDomainsRaw = bypassDomains.filter { $0 != domain }.joined(separator: "\n")
    }
}
