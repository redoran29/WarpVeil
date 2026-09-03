import SwiftUI

struct RoutingView: View {
    var app: AppState

    // Must stay here: AppState reads the key straight from UserDefaults, which @Observable
    // does not track, so the editing view is what triggers the re-render.
    @AppStorage("bypassDomains") private var bypassDomainsRaw = ""
    @AppStorage("bypassEnabled") private var bypassEnabled = true

    @State private var newDomain = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $bypassEnabled) {
                    Text("Domain bypass")
                    Text("Route the domains below outside the tunnel")
                }
            }

            if bypassEnabled {
                Section("Domains") {
                    ForEach(app.bypassDomains, id: \.self) { domain in
                        LabeledContent(domain) {
                            Button {
                                removeDomain(domain)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }

                    TextField("example.com", text: $newDomain)
                        .onSubmit(addDomain)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 520)
        .onChange(of: bypassDomainsRaw) { app.routingChanged() }
        .onChange(of: bypassEnabled) { app.routingChanged() }
    }

    private func addDomain() {
        let domain = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        guard !domain.isEmpty, !app.bypassDomains.contains(domain) else { return }
        bypassDomainsRaw += (bypassDomainsRaw.isEmpty ? "" : "\n") + domain
        newDomain = ""
    }

    private func removeDomain(_ domain: String) {
        bypassDomainsRaw = app.bypassDomains.filter { $0 != domain }.joined(separator: "\n")
    }
}
