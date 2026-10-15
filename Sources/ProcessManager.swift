import Foundation
import AppKit
import Network
import SystemConfiguration

@Observable
@MainActor
final class ProcessManager {
    var logs: [String] = []
    var isRunning = false {
        didSet { if !isRunning { isTunnelUp = false } }
    }
    // The session starts before any engine — while a name resolves, xray comes up and, without
    // passwordless, a password dialog waits — and the tunnel counts as up once the engine shell
    // says sing-box started: its own line, not upstream's wording. What the UI calls Connected.
    private(set) var isTunnelUp = false
    private static let engineStartedMarker = "[sing-box] started"

    private var helperProcess: Process?
    private var xrayProcess: Process?
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

    // The sing-box run.sh starts is a root-owned copy taken while the user typed the password,
    // so a bundle binary swapped later is never what sudoers lets through. "Installed" means
    // the copy is still byte-for-byte the bundled one — an engine bump reads as stale.
    private static let rootSingBoxPath = "/usr/local/libexec/warpveil-\(versionTag)/sing-box"

    // Root-owned. sing-box's PID file lives here, not in the world-writable /tmp, where root's
    // write would follow a symlink planted at its name; it stays readable for install.sh. The
    // configs go one level down, 0700: the engine runs root's copy of the config, so what
    // passed the policy is what runs.
    private static let runDir = "/var/run/warpveil-\(versionTag)"
    private static let stageDir = "/var/run/warpveil-\(versionTag)/stage"

    // PID files: run.sh and stop.sh kill exactly our sing-box, nothing else on the machine. xray
    // runs as the user, so its file is the app's own, in $TMPDIR — the next connect and the
    // sweeps in install.sh and dev-run.sh read it.
    private static let singboxPidFile = "/var/run/warpveil-\(versionTag)/singbox.pid"
    private static let xrayPidFile = FileManager.default.temporaryDirectory.path + "/warpveil-\(versionTag)-xray.pid"

    // xray's SOCKS inbound, which the TUN wrapper forwards everything to.
    nonisolated static let xraySocksPort: UInt16 = 10808

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

    // What a config may ask of a root sing-box. Out: everything that names a file or a
    // directory (sing-box reads and writes them as root), what changes the system
    // (ntp.write_to_system) and what runs a program (tor). Keys are compared lowercased and a
    // non-ASCII key is refused outright: the engine's JSON decoder matches field names
    // case-insensitively with Unicode folding, so "OUTPUT" and "timeſtamp" land on the same
    // fields (probed on the bundled build). A `path` is a transport or DoH path, except under
    // a local rule-set or a hosts server, where it is a file. One line per finding, or "ok".
    private static let configPolicy = """
        def lower: with_entries(.key |= ascii_downcase);
        [ if type != "object" then "root is not an object" else
            (keys[] | select(IN(\(BypassService.configSections.map { "\"\($0)\"" }.joined(separator: ", "))) | not) | "top-level key " + .),
            (.. | objects |
              (keys[] | select(test("[^ -~]")) | "non-ASCII key"),
              (lower |
                (keys[] | select(test("(_path|_directory|_file)$|^(output|external_ui|cache_file|acme|write_to_system|download_url|geoip|geosite)") and . != "process_path") | "key " + .),
                (select(has("path") and ((.type | strings | ascii_downcase) | IN("local", "hosts"))) | "path in a " + .type + " object"),
                (.type | strings | ascii_downcase | select(IN("tor", "tailscale")) | "type " + .)))
          end
        ] | if length == 0 then "ok" else .[] end
        """

    // Shared by run.sh and the osascript fallback. stage_config copies the config from stdin
    // into the stage directory, up to 4 MiB, and prints the copy's path — root never opens a
    // path a caller chose; check_config runs the policy on that copy. Both exit before any
    // engine is touched, so a refused connect leaves a running tunnel up. jq runs with an empty
    // environment: it loads ~/.jq on start, and sudo passes the caller's HOME through. jq ships
    // with macOS 15.
    private static let configFunctions = """
        prepare_dir() {
            mkdir -p -m "$2" "$1"
            [[ ! -L "$1" && "$(stat -f %u "$1")" == 0 ]] || { echo "[error] $1 is not root-owned" >&2; exit 1; }
            chmod "$2" "$1"
        }
        stage_config() {
            local dst
            prepare_dir '\(runDir)' 0755
            prepare_dir '\(stageDir)' 0700
            dst=$(mktemp '\(stageDir)/singbox.XXXXXX') || exit 1
            trap 'rm -f "$dst"' EXIT
            head -c 4194304 > "$dst"
            [[ -s "$dst" ]] || { echo '[error] no config on stdin' >&2; exit 1; }
            [[ $(wc -c < "$dst") -lt 4194304 ]] || { echo '[error] config is 4 MiB or larger' >&2; exit 1; }
            trap - EXIT
            echo "$dst"
        }
        check_config() {
            local verdict
            [[ -x /usr/bin/jq ]] || { echo '[error] /usr/bin/jq not found: macOS 15 or newer is required' >&2; exit 1; }
            verdict=$(env -i /usr/bin/jq -r '\(configPolicy)' "$1" 2>&1) || { echo "[error] config is not valid JSON: $verdict" >&2; exit 1; }
            [[ "$verdict" == ok ]] || { echo "[error] config rejected: $verdict" >&2; exit 1; }
        }
        """

    // The engine start shared by run.sh (the root-owned copy, config on stdin) and the
    // osascript fallback (the bundled binary, the app's file read as the user). PATH and
    // HOME are pinned first: sudo passes the caller's through, and every name below would
    // resolve against them as root. Then stage, check, and only then kill the previous engine.
    // The EXIT trap removes the staged copy however the shell ends — the osascript shell never
    // sees a TERM — and the PID file once it is ours, unless a newer run.sh already wrote its own.
    private static func engineShell(binary: String, configReader: String) -> String {
        """
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export HOME=/var/empty
        \(configFunctions)
        \(killPidFileFunction)
        CFG=$(\(configReader) | stage_config) || exit 1
        trap 'rm -f "$CFG"' EXIT
        check_config "$CFG"
        kill_pid_file \(singboxPidFile) sing-box || { echo '[error] previous sing-box still running'; exit 1; }
        cd '\(stageDir)'
        echo '[sing-box] starting...'
        \(binary) run -c "$CFG" &
        VPN_PID=$!
        echo $VPN_PID > \(singboxPidFile)
        echo "\(engineStartedMarker) pid=$VPN_PID"
        trap 'rm -f "$CFG"; [[ "$(cat \(singboxPidFile) 2>/dev/null)" != "$VPN_PID" ]] || rm -f \(singboxPidFile)' EXIT
        cleanup() {
            echo '[stopping...]'
            kill $VPN_PID 2>/dev/null || true
            wait
            echo '[stopped]'
            exit 0
        }
        trap cleanup TERM INT
        wait
        """
    }

    // run.sh: the config comes on stdin; the binary is the root-owned copy.
    private static let runShContent: String = """
        #!/bin/bash
        set -euo pipefail
        [[ $# -eq 0 ]] || { echo '[error] usage: run.sh < singbox_cfg'; exit 1; }
        \(engineShell(binary: "'\(rootSingBoxPath)'", configReader: "cat"))
        """

    // stop.sh: reads the PID file and kills only our sing-box
    private static let stopShContent: String = """
        #!/bin/bash
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        \(killPidFileFunction)
        kill_pid_file \(singboxPidFile) sing-box
        """

    private var lastConnection: (config: String, xrayPath: String, singBoxPath: String,
                                  bypassDomains: [String])?
    private var wakeObserver: Any?
    private var reconnectTask: Task<Void, Never>?
    private var ipv6Watcher: SCDynamicStore?
    private var ipv6CheckTask: Task<Void, Never>?
    private var tunHasIPv6 = false
    private static let globalIPv6Key = "State:/Network/Global/IPv6"

    // MARK: - Passwordless mode

    // Passwordless is on only while the installed scripts are the ones this build would install
    // and the root-owned sing-box is the bundled one. Only an explicit install writes to
    // /usr/local/libexec, so after a script change or an engine bump an existing install would
    // keep running the old files indefinitely; instead it reads as off, the log says why, and
    // the toggle re-installs. The bundle cannot change under a running app and the root copy
    // only through install/remove, so the 83 MB comparison runs at launch and after those.
    private var rootCopyMatches = ProcessManager.rootCopyMatchesBundle()
    var isPasswordless = false
    var isPasswordlessBusy = false

    private static func scriptsInstalled() -> Bool {
        FileManager.default.fileExists(atPath: sudoersFile)
            && (try? String(contentsOfFile: runScriptPath, encoding: .utf8)) == runShContent
            && (try? String(contentsOfFile: stopScriptPath, encoding: .utf8)) == stopShContent
    }

    // Mapped pages compare in ~10 ms warm, against ~80 ms for contentsEqual's reads.
    private static func rootCopyMatchesBundle() -> Bool {
        guard let bundled = findBinary("sing-box"),
              let root = try? Data(contentsOf: URL(fileURLWithPath: rootSingBoxPath), options: .alwaysMapped),
              let bundle = try? Data(contentsOf: URL(fileURLWithPath: bundled), options: .alwaysMapped)
        else { return false }
        return root == bundle
    }

    func installPasswordless() {
        guard !isPasswordlessBusy else { return }
        guard let bundledSingBox = Self.findBinary("sing-box") else {
            logs.append("[Error: bundled sing-box not found]")
            return
        }
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

        // One osascript call. Every other build's entry goes first — an older run.sh with the
        // hole stays exploitable for as long as its sudoers line exists, and the pre-rename
        // `vpnswift` entry pointed at a script in /private/tmp that anyone can create.
        let shellCmd = """
            rm -f /etc/sudoers.d/warpveil* /etc/sudoers.d/vpnswift && \
            rm -rf /usr/local/libexec/warpveil* && \
            mkdir -p '\(Self.libexecDir)' && \
            install -m 0755 -o root -g wheel \(Self.shellEscape(bundledSingBox)) '\(Self.rootSingBoxPath)' && \
            install -m 0755 -o root -g wheel \(Self.shellEscape(tmpRun)) '\(Self.runScriptPath)' && \
            install -m 0755 -o root -g wheel \(Self.shellEscape(tmpStop)) '\(Self.stopScriptPath)' && \
            rm -f \(Self.shellEscape(tmpRun)) \(Self.shellEscape(tmpStop)) && \
            visudo -cf \(Self.shellEscape(tmpSudoers)) && \
            install -m 0440 -o root -g wheel \(Self.shellEscape(tmpSudoers)) '\(Self.sudoersFile)' && \
            rm -f \(Self.shellEscape(tmpSudoers))
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

        // Off means off for every build: the other tags' entries are the same hole.
        let shellCmd = "rm -f /etc/sudoers.d/warpveil* /etc/sudoers.d/vpnswift && rm -rf /usr/local/libexec/warpveil*"
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

    // Enabling passwordless in another build removes this one's install while it runs, so every
    // privileged call re-reads it. Not during an install: the toggle is flipped optimistically.
    private func refreshPasswordless() {
        guard !isPasswordlessBusy else { return }
        isPasswordless = rootCopyMatches && Self.scriptsInstalled()
    }

    // Called on both success and failure of install/remove — reconciles isPasswordless
    // with the actual filesystem state (in case optimistic flip was wrong) and clears busy.
    private func passwordlessOperationFinished() {
        rootCopyMatches = Self.rootCopyMatchesBundle()
        isPasswordlessBusy = false
        refreshPasswordless()
    }

    init() {
        refreshPasswordless()
        if FileManager.default.fileExists(atPath: Self.sudoersFile), !isPasswordless {
            logs.append("[Passwordless install is from another build — turn Passwordless on again in Advanced]")
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
            connect(config: params.config, xrayPath: params.xrayPath, singBoxPath: params.singBoxPath,
                    bypassDomains: params.bypassDomains)
        }
    }

    // MARK: - Connect / Disconnect

    func connect(config: String, xrayPath: String, singBoxPath: String, bypassDomains: [String] = []) {
        guard !isRunning else { return }
        // A connect supersedes a pending restart: left alone it would connect a second time,
        // and without passwordless ask for the password again.
        reconnectTask?.cancel()
        reconnectTask = nil
        // A stop still running would read the PID file the new run.sh writes and kill the fresh
        // engine or delete its only handle. Without passwordless it is the first of two password
        // dialogs, so the connect waits for its answer, however long that takes.
        // An xray still exiting holds the port the next one needs.
        let exiting = [teardownProcess, xrayProcess].compactMap { $0 }.filter(\.isRunning)
        if !exiting.isEmpty {
            logs.append("[Waiting for the previous engines to stop...]")
            reconnectTask = Task {
                while exiting.contains(where: \.isRunning), !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled else { return }
                connect(config: config, xrayPath: xrayPath, singBoxPath: singBoxPath, bypassDomains: bypassDomains)
            }
            return
        }
        guard !config.isEmpty else {
            logs.append("[Error: no config provided]")
            return
        }
        for binary in [xrayPath, singBoxPath] where !FileManager.default.isExecutableFile(atPath: binary) {
            logs.append("[Error: binary not found at \(binary)]")
            return
        }
        // Without the server's address the wrapper has no rule for xray's own dial, which would
        // loop back through the TUN with nothing in Logs.
        guard let serverHost = BypassService.xrayServerHost(config) else {
            logs.append("[Error: the server's address is not in its config]")
            return
        }

        lastConnection = (config, xrayPath, singBoxPath, bypassDomains)

        if !bypassDomains.isEmpty {
            logs.append("[Bypass] \(bypassDomains.count) domain(s) will route direct")
        }

        refreshPasswordless()
        logs.append(isPasswordless ? "[Connecting...]" : "[Connecting (password prompt)...]")

        // 0600: other local users shouldn't read VPN logs. One append-mode handle for everything
        // that writes it — xray, the helper and its sing-box share one file offset, so their
        // lines interleave instead of overwriting each other.
        FileManager.default.createFile(atPath: logFile, contents: nil, attributes: [.posixPermissions: 0o600])
        let logDescriptor = open(logFile, O_WRONLY | O_APPEND)
        guard logDescriptor >= 0 else {
            logs.append("[Error: cannot open the log file]")
            return
        }
        let engineLog = FileHandle(fileDescriptor: logDescriptor, closeOnDealloc: true)

        startLogTail()

        // The session starts here, before any engine is up, so disconnect, restart, wake and
        // quit see it and a second connect is refused. The start waits in reconnectTask; whoever
        // cancels it — disconnect, restart, wake — tears the session down itself, so a cancelled
        // start touches nothing.
        isRunning = true
        // Read now, not after the lookup: the IPv6 watcher compares the host with this value as
        // soon as the session exists.
        let hostHasIPv6 = hostIPv6State() ?? true
        tunHasIPv6 = hostHasIPv6
        reconnectTask = Task {
            // xray dials a server given by name while the wrapper routes that dial by address,
            // so the name is resolved here and both engines get the same addresses.
            var xrayConfig = config
            var addresses = Self.ipLiteral(serverHost).map { [$0] } ?? []
            let isName = addresses.isEmpty
            if isName {
                addresses = await resolve(serverHost)
                guard !Task.isCancelled else { return }
                guard !addresses.isEmpty else {
                    reconnectTask = nil
                    abandonStart()
                    return
                }
                xrayConfig = BypassService.pinXrayServer(config, host: serverHost, addresses: addresses)
            }
            let dialerPath = isName ? Self.kernelPath(xrayPath) : nil
            writeConfigs(xray: xrayConfig, serverAddresses: addresses, dialerPath: dialerPath,
                         bypassDomains: bypassDomains, hostHasIPv6: hostHasIPv6)
            // The wrapper sends everything to xray's port, so it starts once xray listens.
            let started = await startXray(binaryPath: xrayPath, configFile: xrayConfigFile, log: engineLog)
            guard !Task.isCancelled else { return }
            reconnectTask = nil
            guard started else {
                abandonStart()
                return
            }
            startHelper(singBoxPath: singBoxPath, log: engineLog)
        }
    }

    // A wake or a network change restarts before the new network may answer, so a lookup that
    // fails is retried until half a minute has passed — the last lookup may run past it by its
    // own timeout, which nothing can cut short.
    private func resolve(_ host: String) async -> [String] {
        logs.append("[Resolving \(host)...]")
        let deadline = ContinuousClock.now + .seconds(30)
        while !Task.isCancelled {
            let addresses = await Task.detached { BypassService.resolveAddresses(of: host) }.value
            if !addresses.isEmpty { return addresses }
            guard ContinuousClock.now + .seconds(2) < deadline else { break }
            try? await Task.sleep(for: .seconds(2))
        }
        if !Task.isCancelled { logs.append("[Error: \(host) does not resolve]") }
        return []
    }

    // The executable's path as the kernel reports it and sing-box compares it: symlinks resolved,
    // and `/private` kept — URL's own resolution strips it, which an app run from App
    // Translocation's `/private/var/folders/…` would then never match.
    private static func kernelPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // A link carries an IPv6 address in brackets; xray takes it either way, the wrapper's rule
    // only bare.
    private static func ipLiteral(_ host: String) -> String? {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return IPv4Address(bare) != nil || IPv6Address(bare) != nil ? bare : nil
    }

    // The wrapper is the only sing-box, so the bypass rule and the host's IP families go there:
    // xray gets IP destinations over SOCKS and never sees a domain.
    private func writeConfigs(
        xray: String, serverAddresses: [String], dialerPath: String?, bypassDomains: [String], hostHasIPv6: Bool
    ) {
        FileManager.default.createFile(atPath: xrayConfigFile, contents: xray.data(using: .utf8),
                                        attributes: [.posixPermissions: 0o600])
        let wrapper = BypassService.injectSingBox(
            Self.buildTunWrapperConfig(serverAddresses: serverAddresses, dialerPath: dialerPath), domains: bypassDomains)
        FileManager.default.createFile(atPath: singboxConfigFile,
                                        contents: BypassService.fitTunToHost(wrapper, hostHasIPv6: hostHasIPv6).data(using: .utf8),
                                        attributes: [.posixPermissions: 0o600])
    }

    // A start that failed before the helper ran leaves no root engine to stop.
    private func abandonStart() {
        xrayProcess?.terminate()
        stopLogTail()
        isRunning = false
    }

    private func startHelper(singBoxPath: String, log engineLog: FileHandle) {
        // Re-read: the name lookup and xray's start lie between the connect and here, and another
        // build's toggle may have removed the install meanwhile.
        refreshPasswordless()
        let process = Process()
        if isPasswordless {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = [Self.runScriptPath]
            process.standardInput = FileHandle(forReadingAtPath: singboxConfigFile)
            process.standardOutput = engineLog
            process.standardError = engineLog
        } else {
            let cmd = buildNonPrivilegedShellCommand(singBoxPath: singBoxPath, configFile: singboxConfigFile)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \(Self.appleScriptEscape(cmd)) with administrator privileges"]
        }

        // A helper torn down by a restart can exit after its successor started; only the
        // current one speaks for the connection. xray no longer dies with the helper, so a
        // helper that exits on its own — a refused config, sudo saying no — takes it down here.
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self, self.isRunning, p === self.helperProcess else { return }
                self.isRunning = false
                self.helperProcess = nil
                self.xrayProcess?.terminate()
                self.stopLogTail()
                self.logs.append("[Disconnected (exit \(status))]")
            }
        }

        do {
            try process.run()
            helperProcess = process
        } catch {
            logs.append("[Error: \(error.localizedDescription)]")
            abandonStart()
        }
    }

    // The non-passwordless path: the same engine shell, run by osascript as root with the
    // bundled sing-box — the root-owned copy exists only in passwordless mode. The config is
    // read by a cat running as the user, so a symlink swapped in for the app's file reaches
    // nothing the user could not read. `>>`: xray is already writing the log through the app's
    // append-mode handle.
    private func buildNonPrivilegedShellCommand(singBoxPath: String, configFile: String) -> String {
        let readAsUser = "/usr/bin/sudo -n -u '#\(getuid())' /bin/cat \(Self.shellEscape(configFile))"
        return """
        exec >> \(Self.shellEscape(logFile)) 2>&1
        \(Self.engineShell(binary: Self.shellEscape(singBoxPath), configReader: readAsUser))
        """
    }

    // xray is a SOCKS proxy on loopback and needs no root: it runs as the user, from the bundle.
    // Its dial to the server enters the TUN like any other connection, and the wrapper routes it
    // direct by address — that rule never looks at who dialed. The PID file is the handle on an
    // xray a crashed app left holding the port. True once the port accepts connections.
    private func startXray(binaryPath: String, configFile: String, log: FileHandle) async -> Bool {
        guard await stopOrphanedXray() else {
            if !Task.isCancelled {
                logs.append("[Error: an xray from an earlier run is still running — quit it and connect again]")
            }
            return false
        }
        guard !Task.isCancelled else { return false }
        // Whatever else holds the port would take the wrapper's traffic, and our xray could not bind.
        guard !PingService.isListening(Self.xraySocksPort) else {
            logs.append("[Error: port \(Self.xraySocksPort) is already in use — quit whatever holds it and connect again]")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["run", "-config", configFile]
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self, p === self.xrayProcess else { return }
                self.xrayProcess = nil
                try? FileManager.default.removeItem(atPath: Self.xrayPidFile)
                // The wrapper would keep the TUN and send everything to a dead port. disconnect
                // also cancels a start still waiting for the port.
                guard self.isRunning else { return }
                self.logs.append("[xray exited (exit \(status))]")
                self.disconnect()
            }
        }
        do {
            try process.run()
        } catch {
            logs.append("[Error: cannot start xray: \(error.localizedDescription)]")
            return false
        }
        xrayProcess = process
        try? String(process.processIdentifier).write(toFile: Self.xrayPidFile, atomically: true, encoding: .utf8)
        logs.append("[xray] started pid=\(process.processIdentifier)")

        for _ in 0..<50 {
            guard !Task.isCancelled else { return false }
            guard process.isRunning else {
                logs.append("[Error: xray exited before opening port \(Self.xraySocksPort)]")
                return false
            }
            if PingService.isListening(Self.xraySocksPort) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        logs.append("[Error: xray did not open port \(Self.xraySocksPort) in 5 s]")
        return false
    }

    // Mirrors kill_pid_file: only a live process whose executable is xray is signalled, then
    // given up to 5 s to let go of the port. One that outlives the wait keeps its PID file —
    // the only handle on it — and the connect stops, since the new xray could not bind.
    private func stopOrphanedXray() async -> Bool {
        guard let text = try? String(contentsOfFile: Self.xrayPidFile, encoding: .utf8) else { return true }
        if let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), Self.isXray(pid) {
            kill(pid, SIGTERM)
            var waited = 0
            while Self.isXray(pid), waited < 50, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            guard !Self.isXray(pid) else { return false }
        }
        // Cancelled, the file may already be the next start's.
        guard !Task.isCancelled else { return false }
        try? FileManager.default.removeItem(atPath: Self.xrayPidFile)
        return true
    }

    private nonisolated static func isXray(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).hasSuffix("/xray")
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

    // `dialerPath` is set for a server given by name: its addresses can be a CDN's shared edge,
    // and an address rule alone would send every other site on that edge past the VPN, so only
    // xray's own connections to them go direct. Root can read the socket list this needs (canon,
    // Gotchas); if macOS takes that away, such a server loops — it does not leak.
    private nonisolated static func buildTunWrapperConfig(serverAddresses: [String], dialerPath: String?) -> String {
        var rules: [[String: Any]] = [
            ["action": "hijack-dns", "protocol": "dns"] as [String: Any],
            ["action": "sniff"] as [String: Any]
        ]

        // xray's own connection to the server enters the TUN too; without this rule it would be
        // handed back to xray. By address: the connection arrives as an IP, before sniff, and
        // the SNI a sniff would read is the REALITY camouflage name, never the server's.
        if !serverAddresses.isEmpty {
            let byAddress: [String: Any] = ["ip_cidr": serverAddresses.map { "\($0)/\($0.contains(":") ? 128 : 32)" }]
            var rule: [String: Any] = ["action": "route", "outbound": "direct"]
            if let dialerPath {
                rule["type"] = "logical"
                rule["mode"] = "and"
                rule["rules"] = [byAddress, ["process_path": [dialerPath]]]
            } else {
                rule.merge(byAddress) { $1 }
            }
            rules.insert(rule, at: 0)
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
                    "server_port": xraySocksPort
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
        // A session still waiting for xray has no root engine yet: no stop, and no password
        // dialog for one.
        let helperStarted = helperProcess != nil
        helperProcess?.terminate()
        helperProcess = nil
        xrayProcess?.terminate()
        stopLogTail()
        if helperStarted { killVPNProcesses() }
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
        refreshPasswordless()
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
                export PATH=/usr/bin:/bin:/usr/sbin:/sbin
                \(Self.killPidFileFunction)
                kill_pid_file \(Self.shellEscape(Self.singboxPidFile)) sing-box
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
            Task { @MainActor [weak self] in self?.appendLog(data) }
        }
    }

    // The last poll can miss an engine's final lines — usually the reason it stopped.
    private func stopLogTail() {
        logDebounceTimer?.invalidate()
        logDebounceTimer = nil
        if let handle = logHandle { appendLog(handle.readDataToEndOfFile()) }
        logHandle?.closeFile()
        logHandle = nil
    }

    private func appendLog(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if isRunning, lines.contains(where: { $0.hasPrefix(Self.engineStartedMarker) }) { isTunnelUp = true }
        logs.append(contentsOf: lines)
        if logs.count > 600 {
            logs = Array(logs.suffix(500))
        }
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
