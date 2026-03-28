# WarpVeil UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform WarpVeil from a 750x500 utility window into a compact, premium 420x500 macOS menu bar app following 2026 design best practices.

**Architecture:** Split the monolithic ContentView (581 lines) into focused view files per tab. Reduce window width from 750 to 420px by restructuring Settings (single config editor with Picker instead of side-by-side). Replace custom tab bar with native Picker(.segmented). Add hero status block, collapsible log, material backgrounds, and micro-animations. Move Setup out of permanent tabs into a conditional banner.

**Tech Stack:** Swift 5.10, SwiftUI (macOS 14+), SF Symbols 5, @Observable, @AppStorage

**IMPORTANT — preserve existing fixes:**
- `NetworkMonitor.format()` uses fixed-width padding (`%3d`, `%5.1f`) — DO NOT change this formatting
- `WarpVeilApp` menu bar label uses `.monospacedDigit()` — DO NOT remove this modifier
- Speed display in menu bar must remain (with flag) — it is NOT being removed
- All `@MainActor`, `nonisolated`, shell escape, PID-scoped temp file changes from hardening must be preserved

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/WarpVeilApp.swift` | Modify | Window size 420x500, simplified menu bar label |
| `Sources/ContentView.swift` | Heavy rewrite | Root container: segmented picker, tab switching, modifiers |
| `Sources/DashboardView.swift` | Create | Hero status block, stats row, collapsible log |
| `Sources/RoutingView.swift` | Create | Bypass toggle, domain list, bypass log |
| `Sources/SetupView.swift` | Create | Dependency list, install controls, setup log |
| `Sources/SettingsView.swift` | Create | Paths, passwordless, single config editor with Picker, quit |
| `Sources/StatusIndicator.swift` | Create | Reusable pulse animation indicator |
| `Sources/NetworkMonitor.swift` | Modify | Add downloadHistory/uploadHistory ring buffers for sparkline |

---

## Phase 1: Decompose ContentView & Resize Window

### Task 1: Resize window and simplify menu bar label

**Files:**
- Modify: `Sources/WarpVeilApp.swift`

- [ ] **Step 1: Change window size from 750x500 to 420x500**

```swift
MenuBarExtra {
    ContentView(pm: pm, loc: loc, net: net, setup: setup)
        .frame(width: 420, height: 500)
} label: {
```

- [ ] **Step 2: Update menu bar icon with bounce animation — keep speed text as-is**

Only change the icon SF Symbol and add symbolEffect. Do NOT modify the speed text or `.monospacedDigit()`:

```swift
} label: {
    Image(systemName: pm.isRunning ? "checkmark.shield.fill" : "shield.slash")
        .symbolEffect(.bounce, value: pm.isRunning)
    if pm.isRunning && !net.downloadSpeed.isEmpty {
        Text("\(loc.flag) ↓\(net.downloadSpeed) ↑\(net.uploadSpeed)")
            .monospacedDigit()
    } else if !loc.flag.isEmpty {
        Text(loc.flag)
    }
}
```

- [ ] **Step 3: Build in Xcode (Cmd+B)**

- [ ] **Step 4: Commit**

```bash
git add Sources/WarpVeilApp.swift
git commit -m "feat: resize window to 420x500, simplify menu bar label"
```

---

### Task 2: Create StatusIndicator — reusable pulse animation component

**Files:**
- Create: `Sources/StatusIndicator.swift`

- [ ] **Step 1: Create StatusIndicator.swift**

```swift
import SwiftUI

struct StatusIndicator: View {
    let isConnected: Bool

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Pulse ring (only when connected)
            if isConnected {
                Circle()
                    .stroke(Color.green.opacity(0.4), lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .scaleEffect(isPulsing ? 1.8 : 1.0)
                    .opacity(isPulsing ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: isPulsing)
            }

            // Core circle
            Circle()
                .fill(isConnected ? Color.green : Color.gray)
                .frame(width: 12, height: 12)
        }
        .frame(width: 24, height: 24)
        .onAppear { isPulsing = true }
        .onChange(of: isConnected) { isPulsing = isConnected }
    }
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

- [ ] **Step 3: Commit**

```bash
git add Sources/StatusIndicator.swift
git commit -m "feat: add StatusIndicator with pulse animation"
```

---

### Task 3: Extract DashboardView with hero status block and collapsible log

**Files:**
- Create: `Sources/DashboardView.swift`

- [ ] **Step 1: Create DashboardView.swift with hero block, stats row, and collapsible log**

```swift
import SwiftUI

struct DashboardView: View {
    var pm: ProcessManager
    var loc: LocationService
    var net: NetworkMonitor
    var setup: SetupService
    @Binding var connectedAt: Date?
    var onConnect: () -> Void
    var onDisconnect: () -> Void

    @State private var logExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Setup banner (if dependencies missing)
            if !setup.allInstalled {
                setupBanner
            }

            // Hero status block
            heroBlock
                .padding(16)

            Divider()

            // Stats row (when connected)
            if pm.isRunning {
                statsRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
            }

            // Collapsible log
            logSection

            Spacer(minLength: 0)
        }
    }

    // MARK: - Setup Banner

    private var setupBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Dependencies missing")
                .font(.caption)
            Spacer()
            Text("Go to Setup tab")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Hero Block

    private var heroBlock: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                StatusIndicator(isConnected: pm.isRunning)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pm.isRunning ? "Connected" : "Disconnected")
                        .font(.system(size: 15, weight: .semibold))
                    Text(loc.ip)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if loc.isLoading {
                    ProgressView().scaleEffect(0.6)
                }
                Button { Task { await loc.detect() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Text(loc.location)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if pm.isRunning { onDisconnect() } else { onConnect() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: pm.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 11))
                    Text(pm.isRunning ? "Disconnect" : "Connect")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(pm.isRunning ? .red : .accentColor)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(pm.isRunning ? Color.green.opacity(0.06) : Color.secondary.opacity(0.04))
        )
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack {
            statItem(value: net.downloadSpeed, label: "Download", icon: "arrow.down", color: .blue)
            Spacer()
            statItem(value: net.uploadSpeed, label: "Upload", icon: "arrow.up", color: .orange)
            Spacer()
            if let connectedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    statItem(value: uptimeString(from: connectedAt), label: "Uptime", icon: "clock", color: .secondary)
                }
            }
        }
    }

    private func statItem(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 80)
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { logExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: logExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text("Log")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("(\(pm.logs.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if logExpanded {
                        Button("Clear") { pm.clearLogs() }
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if logExpanded {
                Divider()
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
                    .frame(maxHeight: 200)
                    .onChange(of: pm.logs.count) {
                        proxy.scrollTo(0, anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func uptimeString(from date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

- [ ] **Step 3: Commit**

```bash
git add Sources/DashboardView.swift
git commit -m "feat: add DashboardView with hero block and collapsible log"
```

---

### Task 4: Extract RoutingView

**Files:**
- Create: `Sources/RoutingView.swift`

- [ ] **Step 1: Create RoutingView.swift**

```swift
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

            // Bypass log
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
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

- [ ] **Step 3: Commit**

```bash
git add Sources/RoutingView.swift
git commit -m "feat: add RoutingView with ContentUnavailableView and bordered list"
```

---

### Task 5: Extract SetupView

**Files:**
- Create: `Sources/SetupView.swift`

- [ ] **Step 1: Create SetupView.swift**

Move the `setupTab` content, `depStatusIcon`, and `depStatusLabel` from ContentView into a standalone view. The code is identical to the current implementation but in its own file.

```swift
import SwiftUI

struct SetupView: View {
    var setup: SetupService

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                ForEach(Dependency.allCases) { dep in
                    HStack {
                        depStatusIcon(setup.statuses[dep] ?? .unknown)
                        Text(dep.rawValue)
                            .font(.system(.body, weight: .medium))
                        Spacer()
                        depStatusLabel(setup.statuses[dep] ?? .unknown)
                    }
                }
            }
            .padding(12)

            Divider()

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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Installation Log").font(.caption).fontWeight(.medium)
                    Spacer()
                    if setup.isInstalling { ProgressView().scaleEffect(0.6) }
                    Button("Clear") { setup.logs.removeAll() }.controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(setup.logs.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 0.5)
                                    .id(i)
                            }
                        }
                        .padding(6)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: setup.logs.count) {
                        if let last = setup.logs.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
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
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

- [ ] **Step 3: Commit**

```bash
git add Sources/SetupView.swift
git commit -m "feat: extract SetupView into dedicated file"
```

---

### Task 6: Extract SettingsView with single config editor and Picker

**Files:**
- Create: `Sources/SettingsView.swift`

- [ ] **Step 1: Create SettingsView.swift — single config editor with engine Picker**

Instead of side-by-side config editors (which required 750px), use a Picker to switch between sing-box and xray configs. One editor at full width.

```swift
import SwiftUI

struct SettingsView: View {
    var pm: ProcessManager
    @AppStorage("xrayConfig") private var xrayConfig = ""
    @AppStorage("singBoxConfig") private var singBoxConfig = ""
    @AppStorage("xrayPath") private var xrayPath = ""
    @AppStorage("singBoxPath") private var singBoxPath = ""
    @State private var selectedEngine: ConfigEngine = .singBox

    enum ConfigEngine: String, CaseIterable {
        case singBox = "sing-box"
        case xray = "Xray"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
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
            .formStyle(.grouped)
            .frame(height: 170)

            Divider()

            // Config editor with engine picker
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $selectedEngine) {
                        ForEach(ConfigEngine.allCases, id: \.self) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                TextEditor(text: selectedEngine == .singBox ? $singBoxConfig : $xrayConfig)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
            }

            Divider()

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
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

- [ ] **Step 3: Commit**

```bash
git add Sources/SettingsView.swift
git commit -m "feat: add SettingsView with single config editor and engine picker"
```

---

### Task 7: Rewrite ContentView as thin container with segmented picker

**Files:**
- Modify: `Sources/ContentView.swift` (full rewrite)

- [ ] **Step 1: Replace ContentView with thin container**

Delete all existing content and replace with:

```swift
import SwiftUI

enum Tab: String, CaseIterable {
    case dashboard = "Dashboard"
    case routing = "Routing"
    case setup = "Setup"
    case settings = "Settings"
}

struct ContentView: View {
    var pm: ProcessManager
    var loc: LocationService
    var net: NetworkMonitor
    var setup: SetupService

    @State private var tab: Tab = .dashboard
    @State private var connectedAt: Date?
    @State private var locationTimer: Timer?
    @State private var locationTask: Task<Void, Never>?
    @AppStorage("xrayConfig") private var xrayConfig = ""
    @AppStorage("singBoxConfig") private var singBoxConfig = ""
    @AppStorage("xrayPath") private var xrayPath = ""
    @AppStorage("singBoxPath") private var singBoxPath = ""
    @AppStorage("bypassEnabled") private var bypassEnabled = true
    @AppStorage("bypassDomains") private var bypassDomainsRaw = ""

    private var bypassDomains: [String] {
        bypassDomainsRaw.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented tab picker
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Tab content
            Group {
                switch tab {
                case .dashboard:
                    DashboardView(
                        pm: pm, loc: loc, net: net, setup: setup,
                        connectedAt: $connectedAt,
                        onConnect: doConnect,
                        onDisconnect: doDisconnect
                    )
                case .routing:
                    RoutingView(pm: pm)
                case .setup:
                    SetupView(setup: setup)
                case .settings:
                    SettingsView(pm: pm)
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: tab)
        }
        .background(.ultraThinMaterial)
        .task {
            await loc.detect()
            setup.checkAll()
            if singBoxPath.isEmpty || !FileManager.default.isExecutableFile(atPath: singBoxPath) {
                singBoxPath = ProcessManager.findBinary("sing-box") ?? ""
            }
            if xrayPath.isEmpty || !FileManager.default.isExecutableFile(atPath: xrayPath) {
                xrayPath = ProcessManager.findBinary("xray") ?? ""
            }
        }
        .onChange(of: pm.reconnectCount) {
            connectedAt = Date()
            startLocationTimer()
        }
        .onDisappear {
            locationTask?.cancel()
            locationTimer?.invalidate()
            locationTimer = nil
        }
    }

    // MARK: - Actions

    private func doConnect() {
        pm.connect(
            singBoxPath: singBoxPath, singBoxConfig: singBoxConfig,
            xrayPath: xrayPath, xrayConfig: xrayConfig,
            bypassDomains: bypassEnabled ? bypassDomains : []
        )
        connectedAt = Date()
        startLocationTimer()
    }

    private func doDisconnect() {
        pm.disconnect()
        connectedAt = nil
        locationTask?.cancel()
        locationTimer?.invalidate()
        locationTimer = nil
        locationTask = Task {
            for delay in [3, 5, 10] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                let oldIP = loc.ip
                await loc.detect()
                if loc.ip != oldIP { break }
            }
        }
    }

    private func startLocationTimer() {
        locationTask?.cancel()
        locationTimer?.invalidate()
        locationTask = Task {
            for delay in [3, 5, 10] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                let oldIP = loc.ip
                await loc.detect()
                if loc.ip != oldIP { break }
            }
        }
        locationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { await loc.detect() }
        }
    }
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B) — fix any compilation errors**

The routing `onChange` modifiers for `bypassDomainsRaw` and `bypassEnabled` are now inside `RoutingView` — they were moved in Task 4. Verify there are no duplicate modifiers.

- [ ] **Step 3: Run the app (Cmd+R) and verify all 4 tabs work**

- [ ] **Step 4: Commit**

```bash
git add Sources/ContentView.swift
git commit -m "feat: rewrite ContentView as thin container with segmented picker and material background"
```

---

## Phase 2: Polish & Micro-interactions

### Task 8: Add speed history to NetworkMonitor for future sparkline

**Files:**
- Modify: `Sources/NetworkMonitor.swift`

- [ ] **Step 1: Add ring buffer for speed history**

Add these properties after the existing ones:

```swift
var downloadHistory: [Double] = Array(repeating: 0, count: 60)
var uploadHistory: [Double] = Array(repeating: 0, count: 60)
```

In `tick()`, after computing `dIn`/`dOut` and before `DispatchQueue.main.async`, update the history:

```swift
DispatchQueue.main.async { [self] in
    downloadSpeed = Self.format(dIn)
    uploadSpeed = Self.format(dOut)
    downloadHistory.append(Double(dIn))
    downloadHistory.removeFirst()
    uploadHistory.append(Double(dOut))
    uploadHistory.removeFirst()
}
```

In `stop()`, reset history:

```swift
func stop() {
    timer?.invalidate()
    timer = nil
    uploadSpeed = ""
    downloadSpeed = ""
    downloadHistory = Array(repeating: 0, count: 60)
    uploadHistory = Array(repeating: 0, count: 60)
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

- [ ] **Step 3: Commit**

```bash
git add Sources/NetworkMonitor.swift
git commit -m "feat: add speed history ring buffers to NetworkMonitor"
```

---

### Task 9: Add sparkline to DashboardView

**Files:**
- Modify: `Sources/DashboardView.swift`

- [ ] **Step 1: Add SparklineView as a private struct inside DashboardView.swift**

Add before the closing `}` of DashboardView:

```swift
private struct SparklineView: View {
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
```

- [ ] **Step 2: Add sparkline between stats row and log section**

In `DashboardView.body`, after the stats row block and its `Divider()`, add:

```swift
// Sparkline
if pm.isRunning {
    SparklineView(downloadData: net.downloadHistory, uploadData: net.uploadHistory)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    Divider()
}
```

- [ ] **Step 3: Build in Xcode (Cmd+B)**

- [ ] **Step 4: Commit**

```bash
git add Sources/DashboardView.swift
git commit -m "feat: add sparkline speed graph to dashboard"
```

---

### Task 10: Add numeric text transitions and tab animations

**Files:**
- Modify: `Sources/DashboardView.swift`

- [ ] **Step 1: Add `.contentTransition(.numericText())` to speed values**

In `statItem()`, modify the value Text:

```swift
Text(value)
    .font(.system(size: 14, weight: .semibold, design: .rounded))
    .monospacedDigit()
    .foregroundStyle(color)
    .contentTransition(.numericText())
    .animation(.snappy, value: value)
```

- [ ] **Step 2: Build in Xcode (Cmd+B) and verify speed numbers animate smoothly**

- [ ] **Step 3: Commit**

```bash
git add Sources/DashboardView.swift
git commit -m "feat: add numeric text transitions to speed values"
```

---

### Task 11: Update AGENTS.md with new file structure

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Update Architecture section**

Replace the current file listing with:

```markdown
## Architecture

```
Sources/
├── WarpVeilApp.swift        # @main entry point, MenuBarExtra, service initialization
├── ContentView.swift        # Root container — segmented picker, tab routing, connect/disconnect actions
├── DashboardView.swift      # Hero status block, stats row, sparkline, collapsible log
├── RoutingView.swift        # Bypass toggle, domain list, bypass log
├── SetupView.swift          # Dependency detection UI, installation controls
├── SettingsView.swift       # Binary paths, passwordless, config editor with engine picker, quit
├── StatusIndicator.swift    # Reusable pulse animation indicator
├── ProcessManager.swift     # VPN process lifecycle, sudo/passwordless, log tailing, sleep/wake
├── SetupService.swift       # Dependency detection & installation (Homebrew, sing-box, xray)
├── LocationService.swift    # Public IP & geolocation via ip-api.com
├── NetworkMonitor.swift     # Real-time upload/download speed + 60s history ring buffer
└── BypassService.swift      # JSON config injection for domain bypass routing
```
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: update AGENTS.md with new file structure after UI redesign"
```

---

## Summary

| Phase | Tasks | Commits | What changes |
|-------|-------|---------|-------------|
| 1: Decompose & Resize | 1–7 | 7 | Window 420x500, segmented picker, material bg, hero block, split views |
| 2: Polish | 8–11 | 4 | Sparkline, numeric transitions, AGENTS.md |
| **Total** | **11** | **11** | |

### Key architectural decisions:
- **ContentView drops from 581 → ~120 lines** — thin container only
- **Each tab is its own file** — DashboardView, RoutingView, SetupView, SettingsView
- **Settings uses Picker for config engine** — one editor at full width instead of side-by-side at 375px each
- **Setup stays as a tab** but Dashboard shows a banner when deps are missing
- **Log is collapsible** — DisclosureGroup, collapsed by default
- **No custom tab bar** — native `Picker(.segmented)` for consistency
