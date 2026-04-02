import SwiftUI

struct ServersView: View {
    var pm: ProcessManager
    var loc: LocationService
    var net: NetworkMonitor
    var setup: SetupService
    var subs: SubscriptionService
    @Binding var connectedAt: Date?
    var onConnect: () -> Void
    var onDisconnect: () -> Void

    @AppStorage("selectedServerID") private var selectedServerID = ""
    @State private var showAddSheet = false

    var selectedServer: Server? {
        subs.subscriptions.flatMap(\.servers).first { $0.id.uuidString == selectedServerID }
    }

    var body: some View {
        HSplitView {
            serverList
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
            connectionPanel
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Server List (Left Column)

    private var serverList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Servers")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Task { await subs.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if subs.subscriptions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No subscriptions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Add Subscription") { showAddSheet = true }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(subs.subscriptions) { sub in
                            SubscriptionGroupView(
                                sub: sub,
                                selectedServerID: $selectedServerID,
                                onRefresh: { Task { await subs.refreshSubscription(sub.id) } },
                                onDelete: { subs.removeSubscription(sub.id) }
                            )
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if showAddSheet {
                AddSubscriptionInline(subs: subs, isPresented: $showAddSheet)
                    .padding(.top, 40)
            }
        }
    }

    // MARK: - Connection Panel (Right Column)

    private var connectionPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            if !setup.allInstalled {
                setupBanner
                    .padding(.bottom, 12)
            }

            connectButton
                .padding(.bottom, 16)

            statusBlock
                .padding(.bottom, 16)

            if pm.isRunning {
                statsRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                SparklineView(downloadData: net.downloadHistory, uploadData: net.uploadHistory)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Spacer()

            logSection
        }
    }

    // MARK: - Connect Button

    private var connectButton: some View {
        Button {
            if pm.isRunning { onDisconnect() } else { onConnect() }
        } label: {
            ZStack {
                Circle()
                    .fill(pm.isRunning ? Color.green.opacity(0.15) : Color.secondary.opacity(0.08))
                    .frame(width: 100, height: 100)

                Circle()
                    .fill(pm.isRunning ? Color.green.opacity(0.25) : Color.secondary.opacity(0.12))
                    .frame(width: 80, height: 80)

                Image(systemName: "power")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(pm.isRunning ? .green : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status Block

    private var statusBlock: some View {
        VStack(spacing: 4) {
            Text(pm.isRunning ? "Connected" : "Disconnected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(pm.isRunning ? .green : .secondary)

            if let connectedAt, pm.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(uptimeString(from: connectedAt))
                        .font(.system(size: 20, weight: .light, design: .monospaced))
                        .monospacedDigit()
                }
            }

            if pm.isRunning {
                Text(loc.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let server = selectedServer {
                Text(server.name)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Setup Banner

    private var setupBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("Dependencies missing — check Settings")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack {
            VStack(spacing: 2) {
                Text(net.downloadSpeed)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.blue)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: net.downloadSpeed)
                Text("Download")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(net.uploadSpeed)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: net.uploadSpeed)
                Text("Upload")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let text = pm.logs.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy all logs")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(pm.logs.reversed().enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 0.5)
                                .id(i)
                        }
                    }
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    // MARK: - Helpers

    private func uptimeString(from date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - Sparkline (moved from DashboardView)

struct SparklineView: View {
    let downloadData: [Double]
    let uploadData: [Double]

    var body: some View {
        Canvas { context, size in
            drawLine(context: context, size: size, data: downloadData, color: .blue)
            drawLine(context: context, size: size, data: uploadData, color: .orange.opacity(0.6))
        }
        .frame(height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
    }

    private func drawLine(context: GraphicsContext, size: CGSize, data: [Double], color: Color) {
        let maxVal = max(data.max() ?? 1, 1)
        let stepX = size.width / CGFloat(data.count - 1)
        var path = Path()
        for (i, val) in data.enumerated() {
            let x = CGFloat(i) * stepX
            let y = size.height - (CGFloat(val / maxVal) * size.height * 0.9)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }
}

// MARK: - Subscription Group

private struct SubscriptionGroupView: View {
    let sub: Subscription
    @Binding var selectedServerID: String
    var onRefresh: () -> Void
    var onDelete: () -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { withAnimation { isExpanded.toggle() } } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                Text(sub.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Spacer()

                if !sub.isManual {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Menu {
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.06))

            if isExpanded {
                ForEach(sub.servers) { server in
                    ServerRow(server: server, isSelected: selectedServerID == server.id.uuidString)
                        .onTapGesture { selectedServerID = server.id.uuidString }
                }
            }
        }
    }
}

// MARK: - Server Row

private struct ServerRow: View {
    let server: Server
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(server.protocolType.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
    }
}

// MARK: - Add Subscription Inline

private struct AddSubscriptionInline: View {
    var subs: SubscriptionService
    @Binding var isPresented: Bool

    @State private var isManual = false
    @State private var url = ""
    @State private var manualName = ""
    @State private var manualJSON = ""
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Add Subscription")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Picker("", selection: $isManual) {
                Text("URL").tag(false)
                Text("Manual").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            if isManual {
                TextField("Name", text: $manualName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                TextEditor(text: $manualJSON)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            } else {
                TextField("http://example.com/sub/token", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { addSubscription() }
            }

            HStack {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("Fetching...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add") { addSubscription() }
                    .controlSize(.small)
                    .disabled(isManual ? (manualName.isEmpty || manualJSON.isEmpty) : url.isEmpty)
                    .disabled(isLoading)
            }
        }
        .padding(10)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .padding(.horizontal, 8)
    }

    private func addSubscription() {
        if isManual {
            subs.addManualConfig(name: manualName, json: manualJSON)
            isPresented = false
        } else {
            isLoading = true
            Task {
                await subs.addFromURL(url)
                isLoading = false
                isPresented = false
            }
        }
    }
}
