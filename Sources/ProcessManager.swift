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
    private var lastConnection: (config: String, engine: Engine,
                                  binaryPath: String, singBoxPath: String,
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
            connect(config: params.config, engine: params.engine,
                    binaryPath: params.binaryPath, singBoxPath: params.singBoxPath,
                    bypassDomains: params.bypassDomains)
            reconnectCount += 1
        }
    }

    // MARK: - Connect / Disconnect

    func connect(
        config: String, engine: Engine,
        binaryPath: String, singBoxPath: String = "",
        bypassDomains: [String] = []
    ) {
        guard !isRunning else { return }
        guard !config.isEmpty else {
            logs.append("[Error: no config provided]")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            logs.append("[Error: binary not found at \(binaryPath)]")
            return
        }

        lastConnection = (config, engine, binaryPath, singBoxPath, bypassDomains)

        let finalConfig: String
        let configFile: String
        switch engine {
        case .singBox:
            finalConfig = BypassService.injectSingBox(config, domains: bypassDomains)
            configFile = singboxConfigFile
        case .xray:
            finalConfig = BypassService.injectXray(config, domains: bypassDomains)
            configFile = xrayConfigFile
        }

        FileManager.default.createFile(atPath: configFile, contents: finalConfig.data(using: .utf8),
                                        attributes: [.posixPermissions: 0o600])

        // For xray: generate a sing-box TUN wrapper that routes through xray's SOCKS proxy
        if engine == .xray {
            let tunWrapper = Self.buildTunWrapperConfig(bypassDomains: bypassDomains)
            FileManager.default.createFile(atPath: singboxConfigFile, contents: tunWrapper.data(using: .utf8),
                                            attributes: [.posixPermissions: 0o600])
        }

        if !bypassDomains.isEmpty {
            logs.append("[Bypass] \(bypassDomains.count) domain(s) will route direct")
        }

        logs.append(isPasswordless ? "[Connecting...]" : "[Connecting (password prompt)...]")

        FileManager.default.createFile(atPath: logFile, contents: nil)
        let script = buildScript(engine: engine, binaryPath: binaryPath, singBoxPath: singBoxPath, configFile: configFile)
        FileManager.default.createFile(atPath: runScript, contents: script.data(using: .utf8),
                                        attributes: [.posixPermissions: 0o700])

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

    private func buildScript(engine: Engine, binaryPath: String, singBoxPath: String, configFile: String) -> String {
        var cmds = ["#!/bin/bash", "cd /tmp", "exec > \(Self.shellEscape(logFile)) 2>&1"]
        cmds.append("pkill -f 'sing-box run' 2>/dev/null; pkill -f 'xray run' 2>/dev/null; sleep 1")

        if engine == .xray {
            // Start xray first (SOCKS proxy), then sing-box TUN wrapper
            cmds.append("echo '[xray] starting...'")
            cmds.append("\(Self.shellEscape(binaryPath)) run -config \(Self.shellEscape(configFile)) &")
            cmds.append("XRAY_PID=$!")
            cmds.append("echo '[xray] started pid='$XRAY_PID")
            cmds.append("sleep 1")

            let sbPath = singBoxPath.isEmpty ? binaryPath : singBoxPath
            if let foundSB = Self.findBinary("sing-box") ?? (FileManager.default.isExecutableFile(atPath: sbPath) ? sbPath : nil) {
                cmds.append("echo '[sing-box] starting TUN wrapper...'")
                cmds.append("\(Self.shellEscape(foundSB)) run -c \(Self.shellEscape(singboxConfigFile)) &")
                cmds.append("SINGBOX_PID=$!")
                cmds.append("echo '[sing-box] started pid='$SINGBOX_PID")
            }

            cmds.append("""
                cleanup() { echo '[stopping...]'; kill $XRAY_PID $SINGBOX_PID 2>/dev/null; wait; echo '[stopped]'; exit 0; }
                trap cleanup TERM INT
                wait
                """)
        } else {
            cmds.append("echo '[sing-box] starting...'")
            cmds.append("\(Self.shellEscape(binaryPath)) run -c \(Self.shellEscape(configFile)) &")
            cmds.append("VPN_PID=$!")
            cmds.append("echo '[sing-box] started pid='$VPN_PID")

            cmds.append("""
                cleanup() { echo '[stopping...]'; kill $VPN_PID 2>/dev/null; wait; echo '[stopped]'; exit 0; }
                trap cleanup TERM INT
                wait
                """)
        }

        return cmds.joined(separator: "\n")
    }

    private nonisolated static func buildTunWrapperConfig(bypassDomains: [String]) -> String {
        var rules: [[String: Any]] = [
            ["action": "hijack-dns", "protocol": "dns"] as [String: Any],
            ["action": "sniff"] as [String: Any]
        ]

        if !bypassDomains.isEmpty {
            rules.insert([
                "action": "route",
                "outbound": "direct",
                "domain_suffix": bypassDomains
            ] as [String: Any], at: 0)
        }

        let config: [String: Any] = [
            "log": ["level": "info"],
            "inbounds": [
                [
                    "type": "tun",
                    "tag": "tun-in",
                    "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                    "auto_route": true,
                    "strict_route": true,
                    "sniff": true,
                    "sniff_override_destination": false
                ] as [String: Any]
            ],
            "outbounds": [
                [
                    "type": "socks",
                    "tag": "xray-proxy",
                    "server": "127.0.0.1",
                    "server_port": 10808
                ] as [String: Any],
                ["type": "direct", "tag": "direct"] as [String: Any]
            ],
            "route": [
                "auto_detect_interface": true,
                "default_mark": 233,
                "final": "xray-proxy",
                "rules": rules
            ] as [String: Any],
            "dns": [
                "servers": [
                    ["tag": "remote", "address": "1.1.1.1", "address_resolver": "local", "detour": "xray-proxy"] as [String: Any],
                    ["tag": "local", "address": "8.8.8.8", "detour": "direct"] as [String: Any]
                ],
                "rules": [
                    ["outbound": "any", "server": "local"] as [String: Any]
                ],
                "strategy": "prefer_ipv4",
                "independent_cache": true
            ] as [String: Any]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
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
            connect(config: params.config, engine: params.engine,
                    binaryPath: params.binaryPath, singBoxPath: params.singBoxPath,
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
