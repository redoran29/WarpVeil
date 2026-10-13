import Foundation
import AppKit
import Network
import SystemConfiguration

@Observable
@MainActor
final class ProcessManager {
    var logs: [String] = []
    var isRunning = false

    private var helperProcess: Process?
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

    // PID files: run.sh and stop.sh kill exactly our engines, nothing else on the machine
    private static let singboxPidFile = "/tmp/warpveil-\(versionTag)-singbox.pid"
    private static let xrayPidFile = "/tmp/warpveil-\(versionTag)-xray.pid"

    // Shared by run.sh, stop.sh and the osascript fallbacks. Kills only a process the PID file
    // names whose executable is the given engine, then waits for it to be gone — up to 5 s — so
    // the next sing-box never races the old one for the TUN. A stale or foreign PID is dropped.
    // Returns non-zero, keeping the file, when the engine outlives the wait: with no pkill left
    // that file is the only handle on it, and starting a second engine over a held TUN fails
    // anyway. No SIGKILL — sing-box exits on TERM, and a forced kill leaves its routes behind.
    private static let killPidFileFunction = """
        kill_pid_file() {
            local f="$1" name="$2" pid
            [[ -f "$f" ]] || return 0
            pid=$(cat "$f" 2>/dev/null || true)
            [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$f"; return 0; }
            if [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == *"$name" ]]; then
                kill "$pid" 2>/dev/null || true
                for _ in $(seq 1 50); do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 0.1
                done
                kill -0 "$pid" 2>/dev/null && return 1
            fi
            rm -f "$f"
        }
        """

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

        \(killPidFileFunction)

        kill_pid_file \(singboxPidFile) sing-box || { echo '[error] previous sing-box still running'; exit 1; }
        kill_pid_file \(xrayPidFile) xray || { echo '[error] previous xray still running'; exit 1; }

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
                wait
                rm -f \(xrayPidFile) \(singboxPidFile)
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
                wait
                rm -f \(singboxPidFile)
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
        \(killPidFileFunction)
        kill_pid_file \(singboxPidFile) sing-box
        kill_pid_file \(xrayPidFile) xray
        """

    private var lastConnection: (config: String, engine: Engine,
                                  binaryPath: String, singBoxPath: String,
                                  bypassDomains: [String])?
    private var wakeObserver: Any?
    private var reconnectTask: Task<Void, Never>?
    var reconnectCount = 0
    private var ipv6Watcher: SCDynamicStore?
    private var ipv6CheckTask: Task<Void, Never>?
    private var tunHasIPv6 = false
    private static let globalIPv6Key = "State:/Network/Global/IPv6"

    // MARK: - Passwordless mode

    var isPasswordless = ProcessManager.passwordlessInstalled()
    var isPasswordlessBusy = false

    // Passwordless is on only while the installed scripts are the ones this build would install.
    // Only an explicit install writes to /usr/local/libexec, so after a script change an existing
    // install would keep running the old run.sh indefinitely; instead it reads as off, the log
    // says why, and the toggle re-installs.
    private static func passwordlessInstalled() -> Bool {
        FileManager.default.fileExists(atPath: sudoersFile)
            && (try? String(contentsOfFile: runScriptPath, encoding: .utf8)) == runShContent
            && (try? String(contentsOfFile: stopScriptPath, encoding: .utf8)) == stopShContent
    }

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
        isPasswordless = Self.passwordlessInstalled()
        isPasswordlessBusy = false
    }

    init() {
        if FileManager.default.fileExists(atPath: Self.sudoersFile), !isPasswordless {
            logs.append("[Passwordless scripts are from an older build — turn Passwordless on again in Advanced]")
        }
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
        watchHostIPv6()
    }

    // A restart pending at sleep is re-armed too: its engines are down, and the network needs
    // the same 5 s to settle before they start.
    private func handleWake() {
        guard isRunning || reconnectTask != nil else { return }
        restart("[System woke up — reconnecting...]", after: .seconds(5))
    }

    // The TUN's IP families are fixed when it starts. A network that gains IPv6 mid-session
    // would send it past the VPN, one that loses it would leave bypassed domains with AAAA
    // records the host cannot reach — either way the engines start again.
    private func watchHostIPv6() {
        let box = Unmanaged.passRetained(WeakManager(self))
        var context = SCDynamicStoreContext(version: 0, info: box.toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "WarpVeil" as CFString, { _, _, info in
            guard let info else { return }
            let box = Unmanaged<WeakManager>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in box.manager?.hostIPv6Changed() }
        }, &context),
              SCDynamicStoreSetNotificationKeys(store, [Self.globalIPv6Key] as CFArray, nil),
              SCDynamicStoreSetDispatchQueue(store, .main)
        else {
            box.release()
            logs.append("[Cannot watch the network's IPv6 — reconnect after switching networks]")
            return
        }
        ipv6Watcher = store
    }

    // configd's callback gets a raw pointer; the box keeps it valid without keeping the manager.
    private final class WeakManager {
        weak var manager: ProcessManager?
        init(_ manager: ProcessManager) { self.manager = manager }
    }

    // configd drops and re-adds the key while a network settles, so the host is compared with
    // the TUN 5 s after the first change; later notifications do not move that check, or a
    // flapping key would postpone it for good. The clock stops during sleep, so after wake
    // handleWake's restart is the one that runs.
    private func hostIPv6Changed() {
        guard ipv6CheckTask == nil else { return }
        ipv6CheckTask = Task {
            try? await Task.sleep(for: .seconds(5), clock: .suspending)
            ipv6CheckTask = nil
            guard isRunning, let hostHasIPv6 = hostIPv6State(), hostHasIPv6 != tunHasIPv6 else { return }
            restart("[Network IPv6 changed — reconnecting...]", after: .seconds(1))
        }
    }

    // Starts the engines again from lastConnection as it is when the delay ends, so a routing
    // edit made while the restart is pending is not lost. The delay stops during sleep, so wake
    // can re-arm a pending restart before it fires.
    private func restart(_ message: String, after delay: Duration) {
        guard lastConnection != nil else { return }
        logs.append(message)
        reconnectTask?.cancel()
        if isRunning { tearDownEngines() }

        reconnectTask = Task {
            try? await Task.sleep(for: delay, clock: .suspending)
            guard !Task.isCancelled, let params = lastConnection else { return }
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
        // A connect supersedes a pending restart: left alone it would connect a second time,
        // and without passwordless ask for the password again.
        reconnectTask?.cancel()
        reconnectTask = nil
        // A stop still running would read the PID file the new run.sh writes and kill the fresh
        // engine or delete its only handle. Without passwordless it is the first of two password
        // dialogs, so the connect waits for its answer, however long that takes.
        if let stop = teardownProcess, stop.isRunning {
            logs.append("[Waiting for the previous engines to stop...]")
            reconnectTask = Task {
                while stop.isRunning, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled else { return }
                connect(config: config, engine: engine, binaryPath: binaryPath,
                        singBoxPath: singBoxPath, bypassDomains: bypassDomains)
            }
            return
        }
        guard !config.isEmpty else {
            logs.append("[Error: no config provided]")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            logs.append("[Error: binary not found at \(binaryPath)]")
            return
        }

        lastConnection = (config, engine, binaryPath, singBoxPath, bypassDomains)

        // Whichever sing-box holds the TUN gets the bypass rule and the host's IP families.
        let hostHasIPv6 = hostIPv6State() ?? true
        tunHasIPv6 = hostHasIPv6
        func prepareTunConfig(_ json: String) -> String {
            let injected = BypassService.injectSingBox(json, domains: bypassDomains)
            return BypassService.fitTunToHost(injected, hostHasIPv6: hostHasIPv6)
        }

        let finalConfig: String
        let configFile: String
        switch engine {
        case .singBox:
            finalConfig = prepareTunConfig(config)
            configFile = singboxConfigFile
        case .xray:
            finalConfig = config
            configFile = xrayConfigFile
        }

        FileManager.default.createFile(atPath: configFile, contents: finalConfig.data(using: .utf8),
                                        attributes: [.posixPermissions: 0o600])

        // The wrapper is the only sing-box in the xray topology, so the bypass rule goes there:
        // xray gets IP destinations over SOCKS and never sees a domain.
        if engine == .xray {
            let wrapper = Self.buildTunWrapperConfig(serverIP: Self.extractServerIP(from: config))
            let finalWrapper = prepareTunConfig(wrapper)
            FileManager.default.createFile(atPath: singboxConfigFile, contents: finalWrapper.data(using: .utf8),
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

        // A helper torn down by a restart can exit after its successor started; only the
        // current one speaks for the connection.
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self, self.isRunning, p === self.helperProcess else { return }
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
        cmds.append(Self.killPidFileFunction)
        cmds.append("kill_pid_file \(Self.shellEscape(Self.singboxPidFile)) sing-box || { echo '[error] previous sing-box still running'; exit 1; }")
        cmds.append("kill_pid_file \(Self.shellEscape(Self.xrayPidFile)) xray || { echo '[error] previous xray still running'; exit 1; }")

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
                cleanup() { echo '[stopping...]'; kill $XRAY_PID $SINGBOX_PID 2>/dev/null; wait; rm -f \(Self.shellEscape(Self.xrayPidFile)) \(Self.shellEscape(Self.singboxPidFile)); echo '[stopped]'; exit 0; }
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
                cleanup() { echo '[stopping...]'; kill $VPN_PID 2>/dev/null; wait; rm -f \(Self.shellEscape(Self.singboxPidFile)); echo '[stopped]'; exit 0; }
                trap cleanup TERM INT
                wait
                """)
        }

        return cmds.joined(separator: "\n")
    }

    // configd publishes State:/Network/Global/IPv6 only while a physical service has a routable
    // IPv6; sing-box's TUN registers no configd service, so the answer is the host's. nil when
    // configd cannot say: connect then reads it as yes — an IPv6 address on the TUN costs bypass
    // at worst, a missing one leaks IPv6 — and the change check as no change.
    private func hostIPv6State() -> Bool? {
        guard let store = ipv6Watcher ?? SCDynamicStoreCreate(nil, "WarpVeil" as CFString, nil, nil) else { return nil }
        guard SCDynamicStoreCopyValue(store, Self.globalIPv6Key as CFString) == nil else { return true }
        // nil is also what a failed call returns; only "no such key" means no IPv6.
        return SCError() == kSCStatusNoKey ? false : nil
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

    private nonisolated static func buildTunWrapperConfig(serverIP: String?) -> String {
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

        let config: [String: Any] = [
            "log": ["level": "info"],
            "inbounds": [
                [
                    "type": "tun",
                    "tag": "tun-in",
                    // IPv6 joins at connect time, only when the host has it (fitTunToHost).
                    "address": ["172.19.0.1/30"],
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
                "strategy": "prefer_ipv4"
            ] as [String: Any]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    // Toggling bypass with an empty list, editing the list while bypass is off, or removing and
    // re-adding a domain changes nothing in the routing; without passwordless a reconnect is two
    // admin prompts. While a reconnect is pending, recording the list is enough: it reads it.
    func reconnect(bypassDomains: [String]) {
        guard let params = lastConnection, Set(bypassDomains) != Set(params.bypassDomains) else { return }
        lastConnection?.bypassDomains = bypassDomains
        guard isRunning else { return }
        restart("[Routing changed — reconnecting...]", after: .seconds(1))
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        guard isRunning else { return }
        logs.append("[Disconnecting...]")
        tearDownEngines()
    }

    private func tearDownEngines() {
        helperProcess?.terminate()
        helperProcess = nil
        stopLogTail()
        killVPNProcesses()
        isRunning = false
    }

    // Quit and connect need to know when the engines are actually gone. The non-passwordless
    // path puts up a password dialog, so the wait is however long the user takes.
    private var teardownProcess: Process?

    func awaitTeardown(timeout: TimeInterval) async {
        guard let process = teardownProcess else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func killVPNProcesses() {
        if isPasswordless {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            kill.arguments = [Self.stopScriptPath]
            do {
                try kill.run()
                teardownProcess = kill
            } catch {
                logs.append("[Error: failed to run stop script: \(error.localizedDescription)]")
            }
        } else {
            // The helper stop.sh carries, inline: the libexec copy exists only in passwordless mode.
            let cmd = """
                \(Self.killPidFileFunction)
                kill_pid_file \(Self.shellEscape(Self.singboxPidFile)) sing-box
                kill_pid_file \(Self.shellEscape(Self.xrayPidFile)) xray
                """
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            kill.arguments = ["-e", "do shell script \(Self.appleScriptEscape(cmd)) with administrator privileges"]
            do {
                try kill.run()
                teardownProcess = kill
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
