# WarpVeil Codebase Hardening Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all critical, major, and important issues identified by three independent reviewers (Swift Senior, QA, Architect) — covering security, concurrency, resource leaks, and code quality.

**Architecture:** Incremental fixes organized in 4 phases. Each phase builds on the previous. Phase 1 (security) and Phase 2 (concurrency) are the most impactful — they eliminate the entire class of data races and security vulnerabilities. Phase 3 (resource leaks) and Phase 4 (code quality) are lower-risk improvements.

**Tech Stack:** Swift 5.10, SwiftUI, macOS 14+, @Observable, @MainActor, Swift concurrency

---

## File Map

| File | Changes | Responsibility |
|------|---------|---------------|
| `Sources/ProcessManager.swift` | Heavy modification | Tasks 1–8 |
| `Sources/ContentView.swift` | Heavy modification | Tasks 5, 7, 9, 10, 11, 12 |
| `Sources/SetupService.swift` | Moderate modification | Task 4 |
| `Sources/LocationService.swift` | Light modification | Task 6 |
| `Sources/NetworkMonitor.swift` | Light modification | Task 13 |
| `Sources/BypassService.swift` | Light modification | Task 14 |
| `Sources/WarpVeilApp.swift` | Light modification | Task 8 |

---

## Phase 1: Security (Critical)

### Task 1: Shell escape for binary paths in buildScript

**Addresses:** F-09, S-11, BUG-09 — Shell injection via unescaped `'` in user-provided paths. These paths go into a bash script executed as root via sudo.

**Files:**
- Modify: `Sources/ProcessManager.swift:167-198`

- [ ] **Step 1: Add shell escape helper**

Add this private helper at the bottom of `ProcessManager`, before the closing `}`:

```swift
private static func shellEscape(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
```

- [ ] **Step 2: Use shellEscape in buildScript**

Replace lines 178 and 186 in `buildScript()`. Change:

```swift
cmds.append("'\(xrayPath)' run -config '\(tmp)/xray-config.json' &")
```

to:

```swift
cmds.append("\(Self.shellEscape(xrayPath)) run -config \(Self.shellEscape("\(tmp)/xray-config.json")) &")
```

And change:

```swift
cmds.append("'\(singBoxPath)' run -c '\(tmp)/singbox-config.json' &")
```

to:

```swift
cmds.append("\(Self.shellEscape(singBoxPath)) run -c \(Self.shellEscape("\(tmp)/singbox-config.json")) &")
```

Also escape the logFile path on line 171:

```swift
var cmds = ["#!/bin/bash", "cd /tmp", "exec > \(Self.shellEscape(logFile)) 2>&1"]
```

- [ ] **Step 3: Add path validation in connect()**

At the top of `connect()`, after `let hasSingBox = ...`, add validation:

```swift
if hasXray && !FileManager.default.isExecutableFile(atPath: xrayPath) {
    logs.append("[Error: xray binary not found at \(xrayPath)]")
    return
}
if hasSingBox && !FileManager.default.isExecutableFile(atPath: singBoxPath) {
    logs.append("[Error: sing-box binary not found at \(singBoxPath)]")
    return
}
```

- [ ] **Step 4: Build in Xcode (Cmd+B) and verify no errors**

- [ ] **Step 5: Commit**

```bash
git add Sources/ProcessManager.swift
git commit -m "fix: sanitize shell paths in buildScript to prevent injection"
```

---

### Task 2: Secure temp file handling

**Addresses:** F-02 — Predictable temp file paths enable symlink attacks. Scripts executed as root via sudo.

**Files:**
- Modify: `Sources/ProcessManager.swift:13-14, 131-134, 222-224`

- [ ] **Step 1: Replace static script paths with unique temp files**

Replace the static path constants:

```swift
private static let runScript = "/private/tmp/warpveil-run.sh"
private static let stopScript = "/private/tmp/warpveil-stop.sh"
```

with instance properties that generate unique paths:

```swift
private var runScript: String {
    FileManager.default.temporaryDirectory.path + "/warpveil-run-\(ProcessInfo.processInfo.processIdentifier).sh"
}
private var stopScript: String {
    FileManager.default.temporaryDirectory.path + "/warpveil-stop-\(ProcessInfo.processInfo.processIdentifier).sh"
}
```

- [ ] **Step 2: Set restrictive permissions after writing scripts**

After `try? script.write(toFile: ...)` in `connect()` (around line 134), add:

```swift
chmod(runScript, 0o700)
```

In `disconnect()` after `try? script.write(toFile: ...)` (around line 224), add:

```swift
chmod(stopScript, 0o700)
```

Also set permissions on config files (around line 113-117):

```swift
if hasXray {
    let finalConfig = BypassService.injectXray(xrayConfig, domains: bypassDomains)
    try? finalConfig.write(toFile: "\(tmp)/xray-config.json", atomically: true, encoding: .utf8)
    chmod("\(tmp)/xray-config.json", 0o600)
}
if hasSingBox {
    let finalConfig = BypassService.injectSingBox(singBoxConfig, domains: bypassDomains)
    try? finalConfig.write(toFile: "\(tmp)/singbox-config.json", atomically: true, encoding: .utf8)
    chmod("\(tmp)/singbox-config.json", 0o600)
}
```

- [ ] **Step 3: Update sudoers template in installPasswordless**

The sudoers file references the static runScript/stopScript paths. Update `installPasswordless()` to use the PID-based paths. However, since PID changes each launch, passwordless mode should use a stable path with ownership check. Instead, update the sudoers to allow any `/private/tmp/warpveil-run-*.sh`:

```swift
func installPasswordless() {
    let user = NSUserName()
    let content = """
        \(user) ALL=(ALL) NOPASSWD: /bin/bash /private/tmp/warpveil-run-*.sh
        \(user) ALL=(ALL) NOPASSWD: /bin/bash /private/tmp/warpveil-stop-*.sh

        """
    // ... rest unchanged
}
```

**Note:** Also update the `osascript` argument in `installPasswordless()` that references `Self.sudoersFile` — this remains static, no change needed there.

- [ ] **Step 4: Build in Xcode (Cmd+B) and verify no errors**

- [ ] **Step 5: Commit**

```bash
git add Sources/ProcessManager.swift
git commit -m "fix: use PID-scoped temp files with restrictive permissions"
```

---

### Task 3: Replace try? with proper error handling on critical paths

**Addresses:** F-04, S-05 — Silent failures on script writing and process launch. If disk is full or permissions deny write, the app silently runs a stale/empty script as root.

**Files:**
- Modify: `Sources/ProcessManager.swift:34, 51, 68, 113-117, 134, 224-228, 235`

- [ ] **Step 1: Fix connect() — script write and config writes**

Replace the config write block (lines 111-118):

```swift
if hasXray {
    let finalConfig = BypassService.injectXray(xrayConfig, domains: bypassDomains)
    do {
        try finalConfig.write(toFile: "\(tmp)/xray-config.json", atomically: true, encoding: .utf8)
        chmod("\(tmp)/xray-config.json", 0o600)
    } catch {
        logs.append("[Error: failed to write xray config: \(error.localizedDescription)]")
        return
    }
}
if hasSingBox {
    let finalConfig = BypassService.injectSingBox(singBoxConfig, domains: bypassDomains)
    do {
        try finalConfig.write(toFile: "\(tmp)/singbox-config.json", atomically: true, encoding: .utf8)
        chmod("\(tmp)/singbox-config.json", 0o600)
    } catch {
        logs.append("[Error: failed to write sing-box config: \(error.localizedDescription)]")
        return
    }
}
```

Replace the script write (line 134):

```swift
do {
    try script.write(toFile: runScript, atomically: true, encoding: .utf8)
    chmod(runScript, 0o700)
} catch {
    logs.append("[Error: failed to write run script: \(error.localizedDescription)]")
    return
}
```

- [ ] **Step 2: Fix disconnect() — stop script write**

In `disconnect()`, the passwordless branch (lines 222-228):

```swift
if isPasswordless {
    let script = "#!/bin/bash\npkill -f 'sing-box run' 2>/dev/null\npkill -f 'xray run' 2>/dev/null\n"
    do {
        try script.write(toFile: stopScript, atomically: true, encoding: .utf8)
        chmod(stopScript, 0o700)
    } catch {
        logs.append("[Error: failed to write stop script: \(error.localizedDescription)]")
    }
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    kill.arguments = ["/bin/bash", stopScript]
    do {
        try kill.run()
    } catch {
        logs.append("[Error: failed to run stop script: \(error.localizedDescription)]")
    }
}
```

And the non-passwordless branch (lines 229-235):

```swift
} else {
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    kill.arguments = ["-e", """
        do shell script "pkill -f 'sing-box run'; pkill -f 'xray run'" with administrator privileges
        """]
    do {
        try kill.run()
    } catch {
        logs.append("[Error: failed to run disconnect: \(error.localizedDescription)]")
    }
}
```

- [ ] **Step 3: Fix installPasswordless() and removePasswordless()**

Replace `try? process.run()` in both methods:

```swift
do {
    try process.run()
} catch {
    logs.append("[Error: \(error.localizedDescription)]")
}
```

Also fix the tmpFile write in `installPasswordless()`:

```swift
do {
    try content.write(toFile: tmpFile, atomically: true, encoding: .utf8)
} catch {
    logs.append("[Error: failed to write sudoers temp file: \(error.localizedDescription)]")
    return
}
```

- [ ] **Step 4: Build in Xcode (Cmd+B) and verify no errors**

- [ ] **Step 5: Commit**

```bash
git add Sources/ProcessManager.swift
git commit -m "fix: replace try? with do/catch on critical file writes and process launches"
```

---

## Phase 2: Concurrency & Data Races (Critical)

### Task 4: Add @MainActor to SetupService, remove @unchecked Sendable

**Addresses:** F-05, S-02 — False Sendable conformance hides data races. Properties mutated from Task.detached without compiler verification.

**Files:**
- Modify: `Sources/SetupService.swift:28-29, 60, 105`

- [ ] **Step 1: Replace @unchecked Sendable with @MainActor**

Change the class declaration (line 28-29):

```swift
@Observable
@MainActor
final class SetupService {
```

- [ ] **Step 2: Replace Task.detached with nonisolated helpers**

The `checkAll()` method uses `Task.detached` to run `findBrew()` and `findBinary()` off the main thread (they call `Process.waitUntilExit()`). With `@MainActor`, we need to keep the blocking work off main. Replace `checkAll()`:

```swift
func checkAll() {
    for dep in Dependency.allCases {
        statuses[dep] = .checking
    }

    Task {
        let brew = await Task.detached { Self.findBrew() }.value
        brewPath = brew
        statuses[.homebrew] = brew.map { .installed($0) } ?? .missing

        let sb = await Task.detached { ProcessManager.findBinary("sing-box") }.value
        singBoxPath = sb
        statuses[.singBox] = sb.map { .installed($0) } ?? .missing

        let xr = await Task.detached { ProcessManager.findBinary("xray") }.value
        xrayPath = xr
        statuses[.xray] = xr.map { .installed($0) } ?? .missing
    }
}
```

- [ ] **Step 3: Simplify installAll() — remove MainActor.run wrappers**

Since the class is now `@MainActor`, all property accesses are already on main. Replace `installAll()`:

```swift
func installAll() {
    guard !isInstalling else { return }
    isInstalling = true
    logs.removeAll()

    Task {
        // Step 1: Homebrew
        if case .missing = statuses[.homebrew] {
            await installHomebrew()
        } else if case .failed = statuses[.homebrew] {
            await installHomebrew()
        }

        guard ({ if case .installed = statuses[.homebrew] { return true }; return false }()) else {
            appendLog("[Error] Cannot proceed without Homebrew")
            isInstalling = false
            return
        }

        // Step 2: Packages
        for dep in [Dependency.singBox, Dependency.xray] {
            let s = statuses[dep] ?? .unknown
            if case .installed = s { continue }
            await installFormula(dep)
        }

        isInstalling = false
    }
}
```

- [ ] **Step 4: Simplify installHomebrew() — remove MainActor.run wrappers**

```swift
private func installHomebrew() async {
    statuses[.homebrew] = .installing
    appendLog("[Homebrew] Installing...")

    let success = await runAndStream(
        "/usr/bin/osascript",
        arguments: ["-e", """
            do shell script "NONINTERACTIVE=1 /bin/bash -c \\\"$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\\\"" with administrator privileges
            """]
    )

    let path = Self.findBrew()
    if success, let path {
        brewPath = path
        statuses[.homebrew] = .installed(path)
        appendLog("[Homebrew] Installed at \(path)")
    } else {
        statuses[.homebrew] = .failed("Installation failed")
        appendLog("[Homebrew] Installation failed. Install manually: https://brew.sh")
    }
}
```

- [ ] **Step 5: Simplify installFormula() — remove MainActor.run wrappers**

```swift
private func installFormula(_ dep: Dependency) async {
    guard let formula = dep.formulaName else { return }
    let brew = brewPath ?? "/opt/homebrew/bin/brew"

    statuses[dep] = .installing
    appendLog("[\(dep.rawValue)] Installing via Homebrew...")

    let success = await runAndStream(brew, arguments: ["install", formula])
    let resolved = ProcessManager.findBinary(formula)

    if success, let path = resolved {
        statuses[dep] = .installed(path)
        appendLog("[\(dep.rawValue)] Installed at \(path)")
        switch dep {
        case .singBox: singBoxPath = path
        case .xray:    xrayPath = path
        default: break
        }
    } else {
        statuses[dep] = .failed("Installation failed")
        appendLog("[\(dep.rawValue)] Installation failed")
    }
}
```

- [ ] **Step 6: Fix runAndStream() — dispatch log updates to MainActor**

`runAndStream` uses `readabilityHandler` which fires on a background thread. With `@MainActor` on the class, we need to keep dispatching to main for log updates. The method already uses `DispatchQueue.main.async` for this — but now the `[weak self]` capture in `readabilityHandler` requires `@Sendable`. Add `nonisolated` to avoid compiler warnings, or keep the method as-is since it uses `withCheckedContinuation` which suspends correctly. The key change: the `DispatchQueue.main.async` calls inside the closures are correct and should remain.

No change needed to `runAndStream` — it already dispatches to main.

- [ ] **Step 7: Build in Xcode (Cmd+B) and verify no errors**

- [ ] **Step 8: Commit**

```bash
git add Sources/SetupService.swift
git commit -m "fix: add @MainActor to SetupService, remove @unchecked Sendable"
```

---

### Task 5: Add @MainActor to ProcessManager, fix concurrency

**Addresses:** F-05, S-01, BUG-14 — Properties mutated from DispatchSource on .global() queue, terminationHandler on arbitrary queue. No compiler-verified thread safety.

**Files:**
- Modify: `Sources/ProcessManager.swift` (class declaration, terminationHandler, DispatchSource handler, DispatchQueue.main.async calls)
- Modify: `Sources/ContentView.swift` (doConnect, doDisconnect — now async)

- [ ] **Step 1: Add @MainActor to ProcessManager**

Change the class declaration:

```swift
@Observable
@MainActor
final class ProcessManager {
```

- [ ] **Step 2: Remove DispatchQueue.main.async wrappers in terminationHandler**

In `connect()`, the `terminationHandler` fires on an arbitrary queue. We must dispatch to MainActor. Replace:

```swift
process.terminationHandler = { [weak self] p in
    DispatchQueue.main.async {
        self?.isRunning = false
        self?.stopLogTail()
        self?.logs.append("[Disconnected (exit \(p.terminationStatus))]")
    }
}
```

with:

```swift
process.terminationHandler = { [weak self] p in
    let status = p.terminationStatus
    Task { @MainActor in
        guard let self, self.isRunning else { return }
        self.isRunning = false
        self.stopLogTail()
        self.logs.append("[Disconnected (exit \(status))]")
    }
}
```

Note the `guard self.isRunning` — this prevents the duplicate state update when `disconnect()` already set `isRunning = false` (fixes BUG-04).

- [ ] **Step 3: Fix terminationHandlers in installPasswordless and removePasswordless**

Replace `DispatchQueue.main.async` with `Task { @MainActor in }` in both:

```swift
process.terminationHandler = { [weak self] p in
    Task { @MainActor in
        if p.terminationStatus == 0 {
            self?.isPasswordless = true
            self?.logs.append("[Passwordless mode enabled]")
        } else {
            self?.logs.append("[Failed to enable passwordless mode]")
        }
    }
}
```

Same pattern for `removePasswordless`.

- [ ] **Step 4: Fix DispatchSource handler in startLogTail**

The `DispatchSource` handler runs on `.global()`. Replace:

```swift
source.setEventHandler { [weak self] in
    let data = handle.readDataToEndOfFile()
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
    let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    DispatchQueue.main.async {
        self?.logs.append(contentsOf: lines)
        if let count = self?.logs.count, count > 1000 {
            self?.logs.removeFirst(count - 1000)
        }
    }
}
```

with:

```swift
source.setEventHandler { [weak self] in
    let data = handle.readDataToEndOfFile()
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
    let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    Task { @MainActor in
        self?.logs.append(contentsOf: lines)
        if let count = self?.logs.count, count > 1000 {
            self?.logs.removeFirst(count - 1000)
        }
    }
}
```

- [ ] **Step 5: Build in Xcode (Cmd+B) and fix any remaining isolation warnings**

With `@MainActor`, calls like `DispatchQueue.main.asyncAfter` may produce warnings. We'll address those in Task 7 (reconnect logic). For now, ensure the project builds.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProcessManager.swift
git commit -m "fix: add @MainActor to ProcessManager, fix thread safety in handlers"
```

---

### Task 6: Protect LocationService.detect() from reentrancy

**Addresses:** S-15, BUG-07 — Parallel calls to detect() cause race conditions on ip/location/flag, isLoading flickers.

**Files:**
- Modify: `Sources/LocationService.swift:18-33`

- [ ] **Step 1: Add reentrancy guard**

Replace `detect()`:

```swift
func detect() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    guard let url = URL(string: "http://ip-api.com/json/") else { return }
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        let info = try JSONDecoder().decode(IPInfo.self, from: data)
        ip = info.query
        flag = Self.flag(from: info.countryCode)
        location = "\(flag) \(info.city), \(info.country) — \(info.isp)"
    } catch {
        ip = "Error"
        flag = ""
        location = "Detection failed"
    }
}
```

This is a one-line addition (`guard !isLoading else { return }`). The rest stays the same.

- [ ] **Step 2: Build in Xcode (Cmd+B)**

- [ ] **Step 3: Commit**

```bash
git add Sources/LocationService.swift
git commit -m "fix: prevent reentrant calls to LocationService.detect()"
```

---

### Task 7: Fix reconnect race conditions and cancellation

**Addresses:** BUG-01, S-04, BUG-06 — Double wake triggers double connect. asyncAfter cannot be cancelled. Task leaks in startLocationTimer.

**Files:**
- Modify: `Sources/ProcessManager.swift:79-95, 200-214` (handleWake, reconnect)
- Modify: `Sources/ContentView.swift:62-65, 511-558` (onReconnect, doConnect, doDisconnect, startLocationTimer)

- [ ] **Step 1: Replace DispatchQueue.main.asyncAfter with cancellable Task in ProcessManager**

Add a property to ProcessManager:

```swift
private var reconnectTask: Task<Void, Never>?
```

Replace `handleWake()`:

```swift
private func handleWake() {
    guard let params = lastConnection, isRunning else { return }
    logs.append("[System woke up — reconnecting...]")
    reconnectTask?.cancel()
    helperProcess?.terminate()
    helperProcess = nil
    stopLogTail()
    isRunning = false

    reconnectTask = Task {
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        connect(singBoxPath: params.singBoxPath, singBoxConfig: params.singBoxConfig,
                xrayPath: params.xrayPath, xrayConfig: params.xrayConfig,
                bypassDomains: params.bypassDomains)
        onReconnect?()
    }
}
```

Replace `reconnect()`:

```swift
func reconnect(bypassDomains: [String]) {
    guard isRunning, let params = lastConnection else { return }
    logs.append("[Routing changed — reconnecting...]")
    reconnectTask?.cancel()
    helperProcess?.terminate()
    helperProcess = nil
    stopLogTail()
    isRunning = false

    reconnectTask = Task {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        connect(singBoxPath: params.singBoxPath, singBoxConfig: params.singBoxConfig,
                xrayPath: params.xrayPath, xrayConfig: params.xrayConfig,
                bypassDomains: bypassDomains)
        onReconnect?()
    }
}
```

- [ ] **Step 2: Cancel reconnect in disconnect()**

At the top of `disconnect()`, after `guard isRunning else { return }`:

```swift
reconnectTask?.cancel()
reconnectTask = nil
```

- [ ] **Step 3: Fix onReconnect closure in ContentView**

The current closure `pm.onReconnect = { [self] in ... }` captures a struct copy. Replace the entire `pm.onReconnect` setup in `.task` (ContentView line 62-65) with an `onChange` approach. Remove the onReconnect assignment from `.task`:

```swift
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
```

In ProcessManager, replace `onReconnect` with a counter:

```swift
var reconnectCount = 0
```

Remove the `var onReconnect: (() -> Void)?` property.

In `handleWake()` and `reconnect()`, replace `onReconnect?()` with:

```swift
reconnectCount += 1
```

In ContentView, add an `onChange` after the existing `onChange` modifiers:

```swift
.onChange(of: pm.reconnectCount) {
    connectedAt = Date()
    startLocationTimer()
}
```

- [ ] **Step 4: Fix Task leak in startLocationTimer() and doDisconnect()**

Add a property to ContentView:

```swift
@State private var locationTask: Task<Void, Never>?
```

Replace `startLocationTimer()`:

```swift
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
```

Replace the Task in `doDisconnect()`:

```swift
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
```

- [ ] **Step 5: Build in Xcode (Cmd+B) and verify no errors**

- [ ] **Step 6: Commit**

```bash
git add Sources/ProcessManager.swift Sources/ContentView.swift
git commit -m "fix: cancellable reconnect, fix struct closure capture, prevent Task leaks"
```

---

## Phase 3: Resource Leaks & Lifecycle

### Task 8: Add cleanup on app termination

**Addresses:** F-08 — No cleanup on crash/force quit. VPN processes and TUN interface stay active. wakeObserver never removed.

**Files:**
- Modify: `Sources/ProcessManager.swift:71-77` (init)
- Modify: `Sources/WarpVeilApp.swift`

- [ ] **Step 1: Add willTerminate observer in ProcessManager.init()**

After the existing `wakeObserver` setup in `init()`, add:

```swift
NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification, object: nil, queue: .main
) { [weak self] _ in
    if self?.isRunning == true {
        self?.disconnect()
    }
}
```

- [ ] **Step 2: Add deinit to ProcessManager**

Add after `init()`:

```swift
deinit {
    if let wakeObserver {
        NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
    }
    reconnectTask?.cancel()
    stopLogTail()
}
```

- [ ] **Step 3: Build in Xcode (Cmd+B)**

- [ ] **Step 4: Commit**

```bash
git add Sources/ProcessManager.swift
git commit -m "fix: cleanup VPN processes and observers on app termination"
```

---

### Task 9: Call stopLogTail() in disconnect()

**Addresses:** BUG-03 — FileHandle and DispatchSource leak when disconnect() is called. stopLogTail() only called from terminationHandler which may never fire if process ignores SIGTERM.

**Files:**
- Modify: `Sources/ProcessManager.swift:216-238`

- [ ] **Step 1: Add stopLogTail() call in disconnect()**

After `helperProcess = nil` in `disconnect()`, add `stopLogTail()`:

```swift
func disconnect() {
    guard isRunning else { return }
    reconnectTask?.cancel()
    reconnectTask = nil
    logs.append("[Disconnecting...]")
    helperProcess?.terminate()
    helperProcess = nil
    stopLogTail()
    // ... rest of method
    isRunning = false
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

- [ ] **Step 3: Commit**

```bash
git add Sources/ProcessManager.swift
git commit -m "fix: call stopLogTail() in disconnect() to prevent file handle leak"
```

---

### Task 10: Fix Timer leak on View recreation

**Addresses:** BUG-13, S-06 — MenuBarExtra may recreate ContentView. Timer registered in RunLoop is not invalidated, causing leaked timers and redundant HTTP requests.

**Files:**
- Modify: `Sources/ContentView.swift`

- [ ] **Step 1: Add onDisappear cleanup**

Add `.onDisappear` modifier to the VStack in `body`, after the existing `.onChange` modifiers:

```swift
.onDisappear {
    locationTask?.cancel()
    locationTimer?.invalidate()
    locationTimer = nil
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

- [ ] **Step 3: Commit**

```bash
git add Sources/ContentView.swift
git commit -m "fix: invalidate timer and cancel tasks on view disappear"
```

---

## Phase 4: Code Quality & Performance

### Task 11: Cache bypassLogLines

**Addresses:** F-11, S-07, BUG-11 — O(n*m) filtering of up to 1000 log lines on every render cycle (every second due to NetworkMonitor updates).

**Files:**
- Modify: `Sources/ContentView.swift:408-416`

- [ ] **Step 1: Replace computed property with cached @State**

Add a new state property:

```swift
@State private var cachedBypassLines: [String] = []
```

Replace the computed property `bypassLogLines` with a method:

```swift
private func updateBypassLogLines() {
    let domains = bypassDomains
    guard !domains.isEmpty else {
        cachedBypassLines = []
        return
    }
    cachedBypassLines = pm.logs.filter { line in
        let low = line.lowercased()
        if low.hasPrefix("[bypass]") { return true }
        return domains.contains(where: { low.contains($0) })
    }.reversed()
}
```

- [ ] **Step 2: Add onChange trigger**

Add a new `.onChange` modifier:

```swift
.onChange(of: pm.logs.count) {
    if tab == .routing {
        updateBypassLogLines()
    }
}
.onChange(of: tab) {
    if tab == .routing {
        updateBypassLogLines()
    }
}
```

- [ ] **Step 3: Update references in routingTab**

Replace all occurrences of `bypassLogLines` with `cachedBypassLines` in `routingTab`:

- Line 369: `Text("\(cachedBypassLines.count) entries")`
- Line 378: `if cachedBypassLines.isEmpty {`
- Line 386: `ForEach(Array(cachedBypassLines.enumerated()), id: \.offset) { i, line in`
- Line 400: `.onChange(of: cachedBypassLines.count) {`

- [ ] **Step 4: Build in Xcode (Cmd+B)**

- [ ] **Step 5: Commit**

```bash
git add Sources/ContentView.swift
git commit -m "perf: cache bypass log lines instead of recomputing on every render"
```

---

### Task 12: Use TimelineView for uptime display

**Addresses:** S-08 — Uptime display updates only when other state changes (accidentally via NetworkMonitor). Freezes if no traffic.

**Files:**
- Modify: `Sources/ContentView.swift:129-132`

- [ ] **Step 1: Wrap uptime label in TimelineView**

Replace:

```swift
if let connectedAt {
    Label(uptimeString(from: connectedAt), systemImage: "clock")
        .foregroundStyle(.secondary)
}
```

with:

```swift
if let connectedAt {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
        Label(uptimeString(from: connectedAt), systemImage: "clock")
            .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

- [ ] **Step 3: Commit**

```bash
git add Sources/ContentView.swift
git commit -m "fix: use TimelineView for reliable uptime display updates"
```

---

### Task 13: Remove dead code

**Addresses:** S-17, BUG-12 — `NetworkMonitor.isActive` is unused. `BypassService.isSingBoxConfig` is unused.

**Files:**
- Modify: `Sources/NetworkMonitor.swift:8, 37`
- Modify: `Sources/BypassService.swift:88-96`

- [ ] **Step 1: Remove isActive from NetworkMonitor**

Delete line 8:

```swift
var isActive = false
```

Delete line 37 (inside `tick()`):

```swift
isActive = dIn > 1024 || dOut > 1024
```

Delete the `isActive = false` line in `stop()`.

- [ ] **Step 2: Remove isSingBoxConfig from BypassService**

Delete the entire `isSingBoxConfig` method (lines 88-96):

```swift
static func isSingBoxConfig(_ json: String) -> Bool {
    guard let root = parseJSON(json) else { return false }
    if let outbounds = root["outbounds"] as? [[String: Any]],
       let first = outbounds.first {
        return first["type"] != nil
    }
    return root["route"] != nil
}
```

- [ ] **Step 3: Build in Xcode (Cmd+B) and verify no errors**

- [ ] **Step 4: Commit**

```bash
git add Sources/NetworkMonitor.swift Sources/BypassService.swift
git commit -m "chore: remove dead code (isActive, isSingBoxConfig)"
```

---

### Task 14: Remove .sortedKeys from BypassService serialization

**Addresses:** BUG-16 — `.sortedKeys` rearranges user's config structure unnecessarily, making debugging harder.

**Files:**
- Modify: `Sources/BypassService.swift:107-112`

- [ ] **Step 1: Remove .sortedKeys option**

Replace:

```swift
private static func serializeJSON(_ dict: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
          let str = String(data: data, encoding: .utf8)
    else { return nil }
    return str
}
```

with:

```swift
private static func serializeJSON(_ dict: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
          let str = String(data: data, encoding: .utf8)
    else { return nil }
    return str
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

- [ ] **Step 3: Commit**

```bash
git add Sources/BypassService.swift
git commit -m "fix: preserve original key ordering in serialized JSON configs"
```

---

## Summary

| Phase | Tasks | Commits | Impact |
|-------|-------|---------|--------|
| 1: Security | 1–3 | 3 | Eliminates shell injection, symlink attacks, silent failures |
| 2: Concurrency | 4–7 | 4 | Eliminates all data races, fixes reconnect logic, prevents Task leaks |
| 3: Resource Leaks | 8–10 | 3 | Proper cleanup on termination, fixes file handle and timer leaks |
| 4: Code Quality | 11–14 | 4 | Performance optimization, dead code removal, reliable uptime display |
| **Total** | **14** | **14** | |
