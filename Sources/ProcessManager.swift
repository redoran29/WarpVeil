import Foundation
import AppKit
import Network

@Observable
@MainActor
final class ProcessManager {
    var logs: [String] = []
    var isRunning = false

    private var helperProcess: Process?
    private var logSource: DispatchSourceFileSystemObject?
    private var logHandle: FileHandle?
    private var logDebounceTimer: Timer?
    private let logFile = FileManager.default.temporaryDirectory.path + "/warpveil-\(ProcessManager.versionTag).log"
    private var xrayConfigFile: String {
        FileManager.default.temporaryDirectory.path + "/warpveil-xray-\(ProcessInfo.processInfo.processIdentifier).json"
    }
    private var singboxConfigFile: String {
        FileManager.default.temporaryDirectory.path + "/warpveil-singbox-\(ProcessInfo.processInfo.processIdentifier).json"
    }

    // Version-isolated paths — two different app versions coexist without stepping on each other.
    // `.` → `-` because sudo silently ignores /etc/sudoers.d/ files whose names contain a dot.
    private static let versionTag: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return v.replacingOccurrences(of: ".", with: "-")
    }()

    // Stable, root-owned scripts — no wildcards in sudoers
    private static let libexecDir = "/usr/local/libexec/warpveil-\(versionTag)"
    private static let runScriptPath = "/usr/local/libexec/warpveil-\(versionTag)/run.sh"
    private static let stopScriptPath = "/usr/local/libexec/warpveil-\(versionTag)/stop.sh"
    private static let sudoersFile = "/etc/sudoers.d/warpveil-\(versionTag)"

    // PID files so stop.sh can kill exact processes without pkill -f
    private static let singboxPidFile = "/tmp/warpveil-\(versionTag)-singbox.pid"
    private static let xrayPidFile = "/tmp/warpveil-\(versionTag)-xray.pid"

    // run.sh: validates argv, launches VPN processes, writes PID files
    // argv: run.sh <singbox_path> <singbox_config> [<xray_path> <xray_config>]
    private static let runShContent: String = """
        #!/bin/bash
        set -euo pipefail

        validate_arg() {
            local p="$1"
            [[ "$p" == /* ]] || { echo "[error] not absolute: $p"; exit 1; }
            [[ -e "$p" ]] || { echo "[error] not found: $p"; exit 1; }
            [[ -f "$p" ]] || { echo "[error] not a regular file: $p"; exit 1; }
            [[ ! -L "$p" ]] || { echo "[error] symlink not allowed: $p"; exit 1; }
        }

        if [[ $# -ne 2 && $# -ne 4 ]]; then
            echo "[error] usage: run.sh <singbox> <singbox_cfg> [<xray> <xray_cfg>]"
            exit 1
        fi

        SINGBOX="$1"; SINGBOX_CFG="$2"
        validate_arg "$SINGBOX"
        validate_arg "$SINGBOX_CFG"

        pkill -f 'sing-box run' 2>/dev/null || true
        pkill -f 'xray run' 2>/dev/null || true
        sleep 1

        if [[ $# -eq 4 ]]; then
            XRAY="$3"; XRAY_CFG="$4"
            validate_arg "$XRAY"
            validate_arg "$XRAY_CFG"

            echo '[xray] starting...'
            "$XRAY" run -config "$XRAY_CFG" &
            XRAY_PID=$!
            echo $XRAY_PID > \(xrayPidFile)
            echo "[xray] started pid=$XRAY_PID"
            sleep 1

            echo '[sing-box] starting TUN wrapper...'
            "$SINGBOX" run -c "$SINGBOX_CFG" &
            SINGBOX_PID=$!
            echo $SINGBOX_PID > \(singboxPidFile)
            echo "[sing-box] started pid=$SINGBOX_PID"

            cleanup() {
                echo '[stopping...]'
                kill $XRAY_PID $SINGBOX_PID 2>/dev/null || true
                rm -f \(xrayPidFile) \(singboxPidFile)
                wait
                echo '[stopped]'
                exit 0
            }
            trap cleanup TERM INT
            wait
        else
            echo '[sing-box] starting...'
            "$SINGBOX" run -c "$SINGBOX_CFG" &
            VPN_PID=$!
            echo $VPN_PID > \(singboxPidFile)
            echo "[sing-box] started pid=$VPN_PID"

            cleanup() {
                echo '[stopping...]'
                kill $VPN_PID 2>/dev/null || true
                rm -f \(singboxPidFile)
                wait
                echo '[stopped]'
                exit 0
            }
            trap cleanup TERM INT
            wait
        fi
        """

    // stop.sh: reads PID files and kills only our processes
    private static let stopShContent: String = """
        #!/bin/bash
        kill_pid_file() {
            local f="$1"
            [[ -f "$f" ]] || return 0
            local pid
            pid=$(cat "$f" 2>/dev/null)
            [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$f"; return 0; }
            kill "$pid" 2>/dev/null || true
            rm -f "$f"
        }
        kill_pid_file \(singboxPidFile)
        kill_pid_file \(xrayPidFile)
        """

    private var lastConnection: (config: String, engine: Engine,
                                  binaryPath: String, singBoxPath: String,
                                  bypassDomains: [String])?
    private var wakeObserver: Any?
    private var reconnectTask: Task<Void, Never>?
    var reconnectCount = 0

    // MARK: - Passwordless mode

    var isPasswordless = FileManager.default.fileExists(atPath: sudoersFile)
    var isPasswordlessBusy = false

    func installPasswordless() {
        guard !isPasswordlessBusy else { return }
        isPasswordlessBusy = true
        // Optimistic: flip the toggle visually right away so the click feels responsive.
        // terminationHandler reconciles with the real filesystem state.
        isPasswordless = true

        let user = NSUserName()
        // Exact paths, no wildcards — this is the fix for the LPE
        let sudoersContent = """
            \(user) ALL=(root) NOPASSWD: \(Self.runScriptPath)
            \(user) ALL=(root) NOPASSWD: \(Self.stopScriptPath)

            """
        // Version-tagged temp paths so concurrent installs of different app versions don't collide.
        let tmpSudoers = "/private/tmp/warpveil-\(Self.versionTag)-sudoers"
        let tmpRun = "/private/tmp/warpveil-\(Self.versionTag)-run.sh"
        let tmpStop = "/private/tmp/warpveil-\(Self.versionTag)-stop.sh"
        do {
            try sudoersContent.write(toFile: tmpSudoers, atomically: true, encoding: .utf8)
        } catch {
            logs.append("[Error: failed to write sudoers temp file: \(error.localizedDescription)]")
            passwordlessOperationFinished()
            return
        }

        do {
            try Self.runShContent.write(toFile: tmpRun, atomically: true, encoding: .utf8)
            try Self.stopShContent.write(toFile: tmpStop, atomically: true, encoding: .utf8)
        } catch {
            logs.append("[Error: failed to write helper scripts: \(error.localizedDescription)]")
            passwordlessOperationFinished()
            return
        }

        // Single osascript call: purge v1.0 leftovers, create libexec dir, install scripts, install sudoers.
        // tmpSudoers and helper script paths are hardcoded or system constants — no user input interpolated.
        let shellCmd = """
            rm -f /etc/sudoers.d/warpveil /etc/sudoers.d/warpveil-1-0 && \
            rm -rf /usr/local/libexec/warpveil /usr/local/libexec/warpveil-1-0 && \
            mkdir -p '\(Self.libexecDir)' && \
            install -m 0755 -o root -g wheel '\(Self.shellEscape(tmpRun))' '\(Self.runScriptPath)' && \
            install -m 0755 -o root -g wheel '\(Self.shellEscape(tmpStop))' '\(Self.stopScriptPath)' && \
            rm -f '\(Self.shellEscape(tmpRun))' '\(Self.shellEscape(tmpStop))' && \
            visudo -cf '\(Self.shellEscape(tmpSudoers))' && \
            install -m 0440 -o root -g wheel '\(Self.shellEscape(tmpSudoers))' '\(Self.sudoersFile)' && \
            rm -f '\(Self.shellEscape(tmpSudoers))'
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(Self.appleScriptEscape(shellCmd)) with administrator privileges"]
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                if status == 0 {
                    self.logs.append("[Passwordless mode enabled]")
                } else {
                    self.logs.append("[Failed to enable passwordless mode]")
                }
                self.passwordlessOperationFinished()
            }
        }
        do {
            try process.run()
        } catch {
            logs.append("[Error: \(error.localizedDescription)]")
            passwordlessOperationFinished()
        }
    }

    func removePasswordless() {
        guard !isPasswordlessBusy else { return }
        isPasswordlessBusy = true
        isPasswordless = false

        let shellCmd = "rm -f '\(Self.sudoersFile)' '\(Self.runScriptPath)' '\(Self.stopScriptPath)'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(Self.appleScriptEscape(shellCmd)) with administrator privileges"]
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                if status == 0 {
                    self.logs.append("[Passwordless mode disabled]")
                }
                self.passwordlessOperationFinished()
            }
        }
        do {
            try process.run()
        } catch {
            logs.append("[Error: \(error.localizedDescription)]")
            passwordlessOperationFinished()
        }
    }

    // Called on both success and failure of install/remove — reconciles isPasswordless
    // with the actual filesystem state (in case optimistic flip was wrong) and clears busy.
    private func passwordlessOperationFinished() {
        isPasswordless = FileManager.default.fileExists(atPath: Self.sudoersFile)
        isPasswordlessBusy = false
    }

    init() {
        Self.cleanupStalePidFiles()
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

    // Clear PID markers from previous sessions (graceful exit cleans them via stop.sh;
    // crash does not). Covers current versioned paths plus legacy v1.0 unversioned paths.
    private static func cleanupStalePidFiles() {
        let paths = [
            singboxPidFile, xrayPidFile,
            "/tmp/warpveil-singbox.pid",
            "/tmp/warpveil-xray.pid"
        ]
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
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
            let serverIP = Self.extractServerIP(from: config)
            let tunWrapper = Self.buildTunWrapperConfig(serverIP: serverIP, bypassDomains: bypassDomains)
            FileManager.default.createFile(atPath: singboxConfigFile, contents: tunWrapper.data(using: .utf8),
                                            attributes: [.posixPermissions: 0o600])
        }

        if !bypassDomains.isEmpty {
            logs.append("[Bypass] \(bypassDomains.count) domain(s) will route direct")
        }

        logs.append(isPasswordless ? "[Connecting...]" : "[Connecting (password prompt)...]")

        // 0600: other local users shouldn't read VPN logs
        FileManager.default.createFile(atPath: logFile, contents: nil, attributes: [.posixPermissions: 0o600])

        startLogTail()

        let process = Process()
        if isPasswordless {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            if engine == .xray {
                let sbPath = singBoxPath.isEmpty ? binaryPath : singBoxPath
                let resolvedSB = Self.findBinary("sing-box") ?? (FileManager.default.isExecutableFile(atPath: sbPath) ? sbPath : binaryPath)
                process.arguments = [Self.runScriptPath, resolvedSB, singboxConfigFile, binaryPath, configFile]
            } else {
                process.arguments = [Self.runScriptPath, binaryPath, configFile]
            }
            process.standardOutput = FileHandle(forWritingAtPath: logFile)
            process.standardError = process.standardOutput
        } else {
            let cmd = buildNonPrivilegedShellCommand(engine: engine, binaryPath: binaryPath, singBoxPath: singBoxPath, configFile: configFile)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \(Self.appleScriptEscape(cmd)) with administrator privileges"]
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

    // Builds the shell command used in the non-passwordless (osascript) path.
    // The stable run.sh is only available after installPasswordless, so we
    // replicate the essential logic inline here for the password-prompt flow.
    private func buildNonPrivilegedShellCommand(engine: Engine, binaryPath: String, singBoxPath: String, configFile: String) -> String {
        var cmds = ["cd /tmp", "exec > \(Self.shellEscape(logFile)) 2>&1"]
        cmds.append("pkill -f 'sing-box run' 2>/dev/null; pkill -f 'xray run' 2>/dev/null; sleep 1")

        if engine == .xray {
            cmds.append("echo '[xray] starting...'")
            cmds.append("\(Self.shellEscape(binaryPath)) run -config \(Self.shellEscape(configFile)) &")
            cmds.append("XRAY_PID=$!")
            cmds.append("echo $XRAY_PID > \(Self.shellEscape(Self.xrayPidFile))")
            cmds.append("echo '[xray] started pid='$XRAY_PID")
            cmds.append("sleep 1")

            let sbPath = singBoxPath.isEmpty ? binaryPath : singBoxPath
            let resolvedSB = Self.findBinary("sing-box") ?? (FileManager.default.isExecutableFile(atPath: sbPath) ? sbPath : binaryPath)
            cmds.append("echo '[sing-box] starting TUN wrapper...'")
            cmds.append("\(Self.shellEscape(resolvedSB)) run -c \(Self.shellEscape(singboxConfigFile)) &")
            cmds.append("SINGBOX_PID=$!")
            cmds.append("echo $SINGBOX_PID > \(Self.shellEscape(Self.singboxPidFile))")
            cmds.append("echo '[sing-box] started pid='$SINGBOX_PID")
            cmds.append("""
                cleanup() { echo '[stopping...]'; kill $XRAY_PID $SINGBOX_PID 2>/dev/null; rm -f \(Self.shellEscape(Self.xrayPidFile)) \(Self.shellEscape(Self.singboxPidFile)); wait; echo '[stopped]'; exit 0; }
                trap cleanup TERM INT
                wait
                """)
        } else {
            cmds.append("echo '[sing-box] starting...'")
            cmds.append("\(Self.shellEscape(binaryPath)) run -c \(Self.shellEscape(configFile)) &")
            cmds.append("VPN_PID=$!")
            cmds.append("echo $VPN_PID > \(Self.shellEscape(Self.singboxPidFile))")
            cmds.append("echo '[sing-box] started pid='$VPN_PID")
            cmds.append("""
                cleanup() { echo '[stopping...]'; kill $VPN_PID 2>/dev/null; rm -f \(Self.shellEscape(Self.singboxPidFile)); wait; echo '[stopped]'; exit 0; }
                trap cleanup TERM INT
                wait
                """)
        }

        return cmds.joined(separator: "\n")
    }

    private nonisolated static func extractServerIP(from config: String) -> String? {
        guard let data = config.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]]
        else { return nil }

        for ob in outbounds {
            // xray format: settings.vnext[0].address
            if let settings = ob["settings"] as? [String: Any],
               let vnext = settings["vnext"] as? [[String: Any]],
               let first = vnext.first,
               let addr = first["address"] as? String {
                return addr
            }
            // sing-box format: server
            if let server = ob["server"] as? String {
                return server
            }
        }
        return nil
    }

    private nonisolated static func buildTunWrapperConfig(serverIP: String?, bypassDomains: [String]) -> String {
        var rules: [[String: Any]] = [
            ["action": "hijack-dns", "protocol": "dns"] as [String: Any],
            ["action": "sniff"] as [String: Any]
        ]

        // CRITICAL: route VPN server directly to avoid routing loop.
        // ip_cidr for literal IP addresses; domain_suffix for hostnames.
        if let addr = serverIP {
            if IPv4Address(addr) != nil || IPv6Address(addr) != nil {
                rules.insert([
                    "action": "route",
                    "outbound": "direct",
                    "ip_cidr": ["\(addr)/\(addr.contains(":") ? 128 : 32)"]
                ] as [String: Any], at: 0)
            } else {
                rules.insert([
                    "action": "route",
                    "outbound": "direct",
                    "domain_suffix": [addr]
                ] as [String: Any], at: 0)
            }
        }

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
                    "strict_route": true
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
                "default_domain_resolver": ["server": "local"] as [String: Any],
                "final": "xray-proxy",
                "rules": rules
            ] as [String: Any],
            "dns": [
                "servers": [
                    ["tag": "remote", "type": "tls", "server": "1.1.1.1", "detour": "xray-proxy"] as [String: Any],
                    ["tag": "local", "type": "tls", "server": "8.8.8.8"] as [String: Any]
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
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            kill.arguments = [Self.stopScriptPath]
            do {
                try kill.run()
            } catch {
                logs.append("[Error: failed to run stop script: \(error.localizedDescription)]")
            }
        } else {
            // Read PID files and kill by PID — avoid pkill -f which can match unrelated processes
            let cmd = """
                kill_pid() { local f="$1"; [ -f "$f" ] || return; local p; p=$(cat "$f"); [ "$p" -eq "$p" ] 2>/dev/null && kill "$p" 2>/dev/null; rm -f "$f"; }
                kill_pid \(Self.shellEscape(Self.singboxPidFile))
                kill_pid \(Self.shellEscape(Self.xrayPidFile))
                """
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            kill.arguments = ["-e", "do shell script \(Self.appleScriptEscape(cmd)) with administrator privileges"]
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

        // Poll log file every 0.25s instead of DispatchSource (which fires per-write, hundreds/sec)
        logDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            Task { @MainActor [weak self] in
                guard let self else { return }
                logs.append(contentsOf: lines)
                if logs.count > 600 {
                    logs = Array(logs.suffix(500))
                }
            }
        }
    }

    private func stopLogTail() {
        logDebounceTimer?.invalidate()
        logDebounceTimer = nil
        logSource?.cancel()
        logSource = nil
        logHandle?.closeFile()
        logHandle = nil
    }

    // MARK: - Binary auto-detection

    nonisolated static func findBinary(_ name: String) -> String? {
        guard let bundled = Bundle.main.resourcePath else { return nil }
        let path = (bundled as NSString).appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private nonisolated static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func appleScriptEscape(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}
