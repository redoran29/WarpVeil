import Foundation
import AppKit

@Observable
@MainActor
final class ProcessManager {
    var logs: [String] = []
    var isRunning = false

    private var helperProcess: Process?
    private var logSource: DispatchSourceFileSystemObject?
    private var logHandle: FileHandle?
    private let logFile = FileManager.default.temporaryDirectory.path + "/warpveil.log"
    private var runScript: String {
        FileManager.default.temporaryDirectory.path + "/warpveil-run-\(ProcessInfo.processInfo.processIdentifier).sh"
    }
    private var stopScript: String {
        FileManager.default.temporaryDirectory.path + "/warpveil-stop-\(ProcessInfo.processInfo.processIdentifier).sh"
    }
    private var xrayConfigFile: String {
        FileManager.default.temporaryDirectory.path + "/warpveil-xray-\(ProcessInfo.processInfo.processIdentifier).json"
    }
    private var singboxConfigFile: String {
        FileManager.default.temporaryDirectory.path + "/warpveil-singbox-\(ProcessInfo.processInfo.processIdentifier).json"
    }
    private static let sudoersFile = "/etc/sudoers.d/warpveil"
    private var lastConnection: (singBoxPath: String, singBoxConfig: String,
                                  xrayPath: String, xrayConfig: String,
                                  bypassDomains: [String])?
    private var wakeObserver: Any?
    private var reconnectTask: Task<Void, Never>?
    var reconnectCount = 0

    // MARK: - Passwordless mode

    var isPasswordless = FileManager.default.fileExists(atPath: sudoersFile)

    func installPasswordless() {
        let user = NSUserName()
        let tmpDir = FileManager.default.temporaryDirectory.path
        let content = """
            \(user) ALL=(ALL) NOPASSWD: /bin/bash \(tmpDir)/warpveil-run-*.sh
            \(user) ALL=(ALL) NOPASSWD: /bin/bash \(tmpDir)/warpveil-stop-*.sh

            """
        let tmpFile = "/private/tmp/warpveil-sudoers"
        do {
            try content.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        } catch {
            logs.append("[Error: failed to write sudoers file: \(error.localizedDescription)]")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
            do shell script "visudo -cf '\(tmpFile)' && install -m 0440 -o root -g wheel '\(tmpFile)' '\(Self.sudoersFile)' && rm -f '\(tmpFile)'" with administrator privileges
            """]
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                if status == 0 {
                    self?.isPasswordless = true
                    self?.logs.append("[Passwordless mode enabled]")
                } else {
                    self?.logs.append("[Failed to enable passwordless mode]")
                }
            }
        }
        do {
            try process.run()
        } catch {
            logs.append("[Error: \(error.localizedDescription)]")
        }
    }

    func removePasswordless() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
            do shell script "rm -f '\(Self.sudoersFile)'" with administrator privileges
            """]
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                if status == 0 {
                    self?.isPasswordless = false
                    self?.logs.append("[Passwordless mode disabled]")
                }
            }
        }
        do {
            try process.run()
        } catch {
            logs.append("[Error: \(error.localizedDescription)]")
        }
    }

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if self?.isRunning == true {
                    self?.disconnect()
                }
            }
        }
    }

    private func handleWake() {
        guard let params = lastConnection, isRunning else { return }
        logs.append("[System woke up — reconnecting...]")
        reconnectTask?.cancel()
        helperProcess?.terminate()
        helperProcess = nil
        stopLogTail()
        killVPNProcesses()
        isRunning = false

        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            connect(singBoxPath: params.singBoxPath, singBoxConfig: params.singBoxConfig,
                    xrayPath: params.xrayPath, xrayConfig: params.xrayConfig,
                    bypassDomains: params.bypassDomains)
            reconnectCount += 1
        }
    }

    // MARK: - Connect / Disconnect

    func connect(
        singBoxPath: String, singBoxConfig: String,
        xrayPath: String, xrayConfig: String,
        bypassDomains: [String] = []
    ) {
        guard !isRunning else { return }

        let hasXray = !xrayConfig.isEmpty && !xrayPath.isEmpty
        let hasSingBox = !singBoxConfig.isEmpty && !singBoxPath.isEmpty

        if hasXray && !FileManager.default.isExecutableFile(atPath: xrayPath) {
            logs.append("[Error: xray binary not found at \(xrayPath)]")
            return
        }
        if hasSingBox && !FileManager.default.isExecutableFile(atPath: singBoxPath) {
            logs.append("[Error: sing-box binary not found at \(singBoxPath)]")
            return
        }

        lastConnection = (singBoxPath, singBoxConfig, xrayPath, xrayConfig, bypassDomains)

        if hasXray {
            let finalConfig = BypassService.injectXray(xrayConfig, domains: bypassDomains)
            FileManager.default.createFile(atPath: xrayConfigFile, contents: finalConfig.data(using: .utf8), attributes: [.posixPermissions: 0o600])
        }
        if hasSingBox {
            let finalConfig = BypassService.injectSingBox(singBoxConfig, domains: bypassDomains)
            FileManager.default.createFile(atPath: singboxConfigFile, contents: finalConfig.data(using: .utf8), attributes: [.posixPermissions: 0o600])
        }

        if !bypassDomains.isEmpty {
            logs.append("[Bypass] \(bypassDomains.count) domain(s) will route direct: \(bypassDomains.joined(separator: ", "))")
        }

        guard hasXray || hasSingBox else {
            logs.append("[Error: no config provided. Go to Settings tab.]")
            return
        }

        logs.append(isPasswordless ? "[Connecting...]" : "[Connecting (password prompt)...]")

        FileManager.default.createFile(atPath: logFile, contents: nil)
        let script = buildScript(hasXray: hasXray, hasSingBox: hasSingBox,
                                 xrayPath: xrayPath, singBoxPath: singBoxPath)
        FileManager.default.createFile(atPath: runScript, contents: script.data(using: .utf8), attributes: [.posixPermissions: 0o700])

        startLogTail()

        let process = Process()
        if isPasswordless {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["/bin/bash", runScript]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", """
                do shell script "bash '\(runScript)'" with administrator privileges
                """]
        }

        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.isRunning = false
                self.stopLogTail()
                self.logs.append("[Disconnected (exit \(status))]")
            }
        }

        do {
            try process.run()
            helperProcess = process
            isRunning = true
        } catch {
            logs.append("[Error: \(error.localizedDescription)]")
            stopLogTail()
        }
    }

    private func buildScript(
        hasXray: Bool, hasSingBox: Bool,
        xrayPath: String, singBoxPath: String
    ) -> String {
        var cmds = ["#!/bin/bash", "cd /tmp", "exec > \(Self.shellEscape(logFile)) 2>&1"]

        // Kill stale processes from previous session (e.g. after sleep/wake)
        cmds.append("pkill -f 'sing-box run' 2>/dev/null; pkill -f 'xray run' 2>/dev/null; sleep 1")

        if hasXray {
            cmds.append("echo '[xray] starting...'")
            cmds.append("\(Self.shellEscape(xrayPath)) run -config \(Self.shellEscape(xrayConfigFile)) &")
            cmds.append("XRAY_PID=$!")
            cmds.append("echo '[xray] started pid='$XRAY_PID")
            if hasSingBox { cmds.append("sleep 1") }
        }

        if hasSingBox {
            cmds.append("echo '[sing-box] starting...'")
            cmds.append("\(Self.shellEscape(singBoxPath)) run -c \(Self.shellEscape(singboxConfigFile)) &")
            cmds.append("SINGBOX_PID=$!")
            cmds.append("echo '[sing-box] started pid='$SINGBOX_PID")
        }

        cmds.append("""
            cleanup() { echo '[stopping...]'; kill $XRAY_PID $SINGBOX_PID 2>/dev/null; wait; echo '[stopped]'; exit 0; }
            trap cleanup TERM INT
            wait
            """)

        return cmds.joined(separator: "\n")
    }

    func reconnect(bypassDomains: [String]) {
        guard isRunning, let params = lastConnection else { return }
        logs.append("[Routing changed — reconnecting...]")
        reconnectTask?.cancel()
        helperProcess?.terminate()
        helperProcess = nil
        stopLogTail()
        killVPNProcesses()
        isRunning = false

        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            connect(singBoxPath: params.singBoxPath, singBoxConfig: params.singBoxConfig,
                    xrayPath: params.xrayPath, xrayConfig: params.xrayConfig,
                    bypassDomains: bypassDomains)
            reconnectCount += 1
        }
    }

    func disconnect() {
        guard isRunning else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        logs.append("[Disconnecting...]")
        helperProcess?.terminate()
        helperProcess = nil
        stopLogTail()
        killVPNProcesses()
        isRunning = false
    }

    private func killVPNProcesses() {
        if isPasswordless {
            let script = "#!/bin/bash\npkill -f 'sing-box run' 2>/dev/null\npkill -f 'xray run' 2>/dev/null\n"
            FileManager.default.createFile(atPath: stopScript, contents: script.data(using: .utf8), attributes: [.posixPermissions: 0o700])
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            kill.arguments = ["/bin/bash", stopScript]
            do {
                try kill.run()
            } catch {
                logs.append("[Error: failed to run stop script: \(error.localizedDescription)]")
            }
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
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Log file tailing

    private func startLogTail() {
        stopLogTail()

        guard let handle = FileHandle(forReadingAtPath: logFile) else { return }
        handle.seekToEndOfFile()
        logHandle = handle

        let fd = handle.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            Task { @MainActor in
                self?.logs.append(contentsOf: lines)
                if let count = self?.logs.count, count > 500 {
                    self?.logs.removeFirst(count - 500)
                }
            }
        }
        source.resume()
        logSource = source
    }

    private func stopLogTail() {
        logSource?.cancel()
        logSource = nil
        logHandle?.closeFile()
        logHandle = nil
    }

    // MARK: - Binary auto-detection

    nonisolated static func findBinary(_ name: String) -> String? {
        // Check well-known paths first (reliable in .app context)
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "\(NSHomeDirectory())/go/bin/\(name)",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Fallback: shell which (may not work in .app bundle)
        if let path = shellCommand("which \(name)"),
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private nonisolated static func shellCommand(_ cmd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
