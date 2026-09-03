import SwiftUI

struct ServersView: View {
    var app: AppState

    @State private var showAddSheet = false
    @State private var subscriptionToDelete: Subscription?

    var body: some View {
        ScrollView {
            serverListSection
                .padding(.vertical, 12)
        }
        .onAppear { app.pingAll() }
        .onDisappear { app.ping.cancel() }
        .sheet(isPresented: $showAddSheet) {
            AddSubscriptionSheet(subs: app.subs)
        }
        .confirmationDialog(
            "Delete \(subscriptionToDelete?.name ?? "")?",
            isPresented: Binding(
                get: { subscriptionToDelete != nil },
                set: { if !$0 { subscriptionToDelete = nil } }
            ),
            presenting: subscriptionToDelete
        ) { sub in
            Button("Delete", role: .destructive) { app.removeSubscription(sub.id) }
        }
    }

    // MARK: - Server List

    private var serverListSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("SERVERS")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                Spacer()
                if app.ping.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Ping all") { app.pingAll() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.indigo)
                        .buttonStyle(.plain)
                        .disabled(app.pm.isRunning)
                        .help(app.pm.isRunning ? "Disconnect to measure" : "Measure every server")
                }
                Button("+ Add") { showAddSheet = true }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.indigo)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            if let error = app.ping.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            if app.subs.subscriptions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text("No servers")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Button("Add subscription") { showAddSheet = true }
                        .font(.system(size: 12))
                        .foregroundStyle(.indigo)
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 2) {
                    ForEach(app.subs.subscriptions) { sub in
                        subscriptionHeader(sub)

                        ForEach(sub.servers) { server in
                            ServerRowView(
                                server: server,
                                isSelected: app.selectedServerID == server.id,
                                ping: app.ping.results[server.id]
                            )
                                .contentShape(Rectangle())
                                .onTapGesture { app.selectedServerID = server.id }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func subscriptionHeader(_ sub: Subscription) -> some View {
        HStack(spacing: 6) {
            Text(sub.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            // A manual subscription's lastUpdated is the moment it was added, which
            // "updated N ago" would misdescribe, and it has nothing to refresh from.
            if !sub.isManual, let updated = sub.lastUpdated {
                Text(updated.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !sub.isManual {
                if app.subs.refreshingIDs.contains(sub.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await app.subs.refreshSubscription(sub.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh subscription")
                }
            }

            Button {
                subscriptionToDelete = sub
            } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete subscription")
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

}

// MARK: - Server Row

private struct ServerRowView: View {
    let server: Server
    let isSelected: Bool
    let ping: PingResult?

    var body: some View {
        HStack(spacing: 12) {
            Text(Self.guessFlag(from: server.name))
                .font(.system(size: 22))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(protocolLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            pingLabel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.lavender.opacity(0.15) : .clear)
        )
    }

    @ViewBuilder
    private var pingLabel: some View {
        switch ping {
        case .measuring:
            ProgressView().controlSize(.small)
        case .delay(let milliseconds):
            Text("\(milliseconds) ms")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Self.color(forDelay: milliseconds))
        case .failed:
            Text("--")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    // A full HEAD request through the proxy, so the bands sit well above TCP-handshake numbers.
    private static func color(forDelay milliseconds: Int) -> Color {
        if milliseconds < 300 { return .green }
        if milliseconds < 800 { return .yellow }
        return .red
    }

    private var protocolLabel: String {
        let proto = server.protocolType.uppercased()
        guard !server.transport.isEmpty, server.transport != "tcp" else { return proto }
        return "\(proto) \u{00B7} \(server.transport.uppercased())"
    }

    private static let flagPatterns: [(String, String)] = [
            ("chicago", "\u{1F1FA}\u{1F1F8}"), ("new york", "\u{1F1FA}\u{1F1F8}"),
            ("los angeles", "\u{1F1FA}\u{1F1F8}"), ("dallas", "\u{1F1FA}\u{1F1F8}"),
            ("miami", "\u{1F1FA}\u{1F1F8}"), ("seattle", "\u{1F1FA}\u{1F1F8}"),
            ("san ", "\u{1F1FA}\u{1F1F8}"), ("washington", "\u{1F1FA}\u{1F1F8}"),
            ("us-", "\u{1F1FA}\u{1F1F8}"), ("usa", "\u{1F1FA}\u{1F1F8}"),
            ("frankfurt", "\u{1F1E9}\u{1F1EA}"), ("berlin", "\u{1F1E9}\u{1F1EA}"),
            ("munich", "\u{1F1E9}\u{1F1EA}"), ("de-", "\u{1F1E9}\u{1F1EA}"),
            ("amsterdam", "\u{1F1F3}\u{1F1F1}"), ("nl-", "\u{1F1F3}\u{1F1F1}"),
            ("london", "\u{1F1EC}\u{1F1E7}"), ("uk-", "\u{1F1EC}\u{1F1E7}"),
            ("paris", "\u{1F1EB}\u{1F1F7}"), ("fr-", "\u{1F1EB}\u{1F1F7}"),
            ("tokyo", "\u{1F1EF}\u{1F1F5}"), ("osaka", "\u{1F1EF}\u{1F1F5}"),
            ("jp-", "\u{1F1EF}\u{1F1F5}"),
            ("singapore", "\u{1F1F8}\u{1F1EC}"), ("sg-", "\u{1F1F8}\u{1F1EC}"),
            ("moscow", "\u{1F1F7}\u{1F1FA}"), ("ru-", "\u{1F1F7}\u{1F1FA}"),
            ("russia", "\u{1F1F7}\u{1F1FA}"),
            ("helsinki", "\u{1F1EB}\u{1F1EE}"), ("fi-", "\u{1F1EB}\u{1F1EE}"),
            ("stockholm", "\u{1F1F8}\u{1F1EA}"), ("se-", "\u{1F1F8}\u{1F1EA}"),
            ("toronto", "\u{1F1E8}\u{1F1E6}"), ("ca-", "\u{1F1E8}\u{1F1E6}"),
            ("sydney", "\u{1F1E6}\u{1F1FA}"), ("au-", "\u{1F1E6}\u{1F1FA}"),
            ("hong kong", "\u{1F1ED}\u{1F1F0}"), ("hk-", "\u{1F1ED}\u{1F1F0}"),
            ("istanbul", "\u{1F1F9}\u{1F1F7}"), ("tr-", "\u{1F1F9}\u{1F1F7}"),
            ("warsaw", "\u{1F1F5}\u{1F1F1}"), ("pl-", "\u{1F1F5}\u{1F1F1}"),
            ("bucharest", "\u{1F1F7}\u{1F1F4}"), ("ro-", "\u{1F1F7}\u{1F1F4}"),
            ("kyiv", "\u{1F1FA}\u{1F1E6}"), ("kiev", "\u{1F1FA}\u{1F1E6}"),
            ("ua-", "\u{1F1FA}\u{1F1E6}"),
            ("tallinn", "\u{1F1EA}\u{1F1EA}"), ("ee-", "\u{1F1EA}\u{1F1EA}"),
            ("riga", "\u{1F1F1}\u{1F1FB}"), ("lv-", "\u{1F1F1}\u{1F1FB}"),
            ("vilnius", "\u{1F1F1}\u{1F1F9}"), ("lt-", "\u{1F1F1}\u{1F1F9}"),
            ("sofia", "\u{1F1E7}\u{1F1EC}"), ("bg-", "\u{1F1E7}\u{1F1EC}"),
            ("prague", "\u{1F1E8}\u{1F1FF}"), ("cz-", "\u{1F1E8}\u{1F1FF}"),
            ("vienna", "\u{1F1E6}\u{1F1F9}"), ("at-", "\u{1F1E6}\u{1F1F9}"),
            ("zurich", "\u{1F1E8}\u{1F1ED}"), ("ch-", "\u{1F1E8}\u{1F1ED}"),
            ("madrid", "\u{1F1EA}\u{1F1F8}"), ("es-", "\u{1F1EA}\u{1F1F8}"),
            ("lisbon", "\u{1F1F5}\u{1F1F9}"), ("pt-", "\u{1F1F5}\u{1F1F9}"),
            ("milan", "\u{1F1EE}\u{1F1F9}"), ("rome", "\u{1F1EE}\u{1F1F9}"),
            ("it-", "\u{1F1EE}\u{1F1F9}"),
            ("seoul", "\u{1F1F0}\u{1F1F7}"), ("kr-", "\u{1F1F0}\u{1F1F7}"),
            ("mumbai", "\u{1F1EE}\u{1F1F3}"), ("in-", "\u{1F1EE}\u{1F1F3}"),
            ("sao paulo", "\u{1F1E7}\u{1F1F7}"), ("br-", "\u{1F1E7}\u{1F1F7}"),
        ]

    private static func guessFlag(from name: String) -> String {
        let lower = name.lowercased()
        for (pattern, flag) in flagPatterns {
            if lower.contains(pattern) { return flag }
        }
        return "\u{1F310}" // globe
    }
}

// MARK: - Add Subscription Sheet

private struct AddSubscriptionSheet: View {
    var subs: SubscriptionService

    @Environment(\.dismiss) private var dismiss

    @State private var isManual = false
    @State private var url = ""
    @State private var manualName = ""
    @State private var manualJSON = ""
    @State private var isLoading = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Add Subscription")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Picker("", selection: $isManual) {
                Text("URL").tag(false)
                Text("JSON").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .onChange(of: isManual) { message = nil }

            if isManual {
                TextField("Name", text: $manualName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                TextEditor(text: $manualJSON)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
            } else {
                TextField("vless:// or subscription URL", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(isLoading)
                    .onSubmit { addSubscription() }
                    .onChange(of: url) { message = nil }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("Loading...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add") { addSubscription() }
                    .controlSize(.small)
                    .disabled(!canSubmit)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var canSubmit: Bool {
        guard !isLoading else { return false }
        return isManual ? !(manualName.isEmpty || manualJSON.isEmpty) : !url.isEmpty
    }

    private func addSubscription() {
        // Enter in a text field reaches here without passing the button's disabled state.
        guard canSubmit else { return }

        if isManual {
            message = subs.addManualConfig(name: manualName, json: manualJSON).message
            if message == nil { dismiss() }
        } else {
            message = nil
            isLoading = true
            Task {
                message = await subs.addFromURL(url).message
                isLoading = false
                if message == nil { dismiss() }
            }
        }
    }
}

private extension AddResult {
    var message: String? {
        switch self {
        case .added: nil
        case .emptyInput: "Enter a link or a subscription URL"
        case .unparsableLink: "Could not parse this link"
        case .duplicateServer: "This server is already in the list"
        case .refreshing(let name): "Already added — \(name) is refreshing now"
        case .emptyFeed: "Could not load a subscription from this link"
        case .invalidJSON: "This is not valid JSON"
        case .refreshFailed(let name): "Could not refresh \(name) — its servers are unchanged"
        }
    }
}
