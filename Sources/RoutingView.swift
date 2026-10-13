import SwiftUI

struct RoutingView: View {
    var app: AppState

    // Must stay here: AppState reads the key straight from UserDefaults, which @Observable
    // does not track, so the editing view is what triggers the re-render.
    @AppStorage("bypassDomains") private var bypassDomainsRaw = ""
    @AppStorage("bypassEnabled") private var bypassEnabled = true

    @State private var newDomain = ""
    @State private var reconnectTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $bypassEnabled) {
                    Text("Domain bypass")
                    Text("Route the domains below outside the tunnel")
                }
            }

            if bypassEnabled {
                Section {
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

                    // A TextField's title is a row label in a grouped Form, so the example
                    // goes in the prompt and the label is hidden.
                    HStack {
                        TextField("Domain", text: $newDomain, prompt: Text("example.com"))
                            .labelsHidden()
                            .onSubmit(addDomains)
                        Button("Add", action: addDomains)
                            .disabled(!canAdd)
                    }
                } header: {
                    Text("Domains")
                } footer: {
                    Text(verbatim: "Subdomains are included: example.com also covers www.example.com. A URL or several domains at once are accepted.")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: bypassDomainsRaw) { scheduleReconnect() }
        .onChange(of: bypassEnabled) { scheduleReconnect() }
    }

    // Every routing change tears the tunnel down and back up, which without passwordless mode
    // means an admin prompt. Adding three domains should cost one, not three.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            app.routingChanged()
        }
    }

    private var canAdd: Bool {
        !BypassService.parseDomains(newDomain).domains.isEmpty
    }

    // Enter reaches here without passing the button's disabled state. Tokens that did not
    // normalize stay in the field so the user sees what was not accepted.
    private func addDomains() {
        let parsed = BypassService.parseDomains(newDomain)
        let fresh = parsed.domains.filter { !app.bypassDomains.contains($0) }
        if !fresh.isEmpty {
            bypassDomainsRaw = (app.bypassDomains + fresh).joined(separator: "\n")
        }
        newDomain = parsed.rejected.joined(separator: " ")
    }

    private func removeDomain(_ domain: String) {
        bypassDomainsRaw = app.bypassDomains.filter { $0 != domain }.joined(separator: "\n")
    }
}
