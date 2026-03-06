import Foundation
import AppKit

@Observable
final class ProcessManager {
    var logs: [String] = []
    var isRunning = false

    private var helperProcess: Process?
    private var logSource: DispatchSourceFileSystemObject?
    private var logHandle: FileHandle?
    private let logFile = FileManager.default.temporaryDirectory.path + "/warpveil.log"
    private static let runScript = "/private/tmp/warpveil-run.sh"
    private static let stopScript = "/private/tmp/warpveil-stop.sh"
    private static let sudoersFile = "/etc/sudoers.d/warpveil"
    private var lastConnection: (singBoxPath: String, singBoxConfig: String,
                                  xrayPath: String, xrayConfig: String)?
    private var wakeObserver: Any?
    var onReconnect: (() -> Void)?

    // MARK: - Passwordless mode

    var isPasswordless = FileManager.default.fileExists(atPath: sudoersFile)

    func installPasswordless() {
        let user = NSUserName()
        let content = """
            \(user) ALL=(ALL) NOPASSWD: /bin/bash \(Self.runScript)
            \(user) ALL=(ALL) NOPASSWD: /bin/bash \(Self.stopScript)

            """
        let tmpFile = "/private/tmp/warpveil-sudoers"
        try? content.write(toFile: tmpFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
            do shell script "visudo -cf '\(tmpFile)' && install -m 0440 -o root -g wheel '\(tmpFile)' '\(Self.sudoersFile)' && rm -f '\(tmpFile)'" with administrator privileges
            """]
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    self?.isPasswordless = true
                    self?.logs.append("[Passwordless mode enabled]")
                } else {
                    self?.logs.append("[Failed to enable passwordless mode]")
                }
            }
        }
        try? process.run()
    }

    func removePasswordless() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
            do shell script "rm -f '\(Self.sudoersFile)'" with administrator privileges
            """]
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    self?.isPasswordless = false
                    self?.logs.append("[Passwordless mode disabled]")
                }
            }
        }
        try? process.run()
    }

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    private func handleWake() {
        guard let params = lastConnection, isRunning else { return }
        logs.append("[System woke up — reconnecting...]")
        // Soft disconnect: just clean up local state, no osascript pkill.
        // The connect script will kill stale processes itself (one password prompt).
        helperProcess?.terminate()
        helperProcess = nil
        stopLogTail()
        isRunning = false
        // Wait for network to come back before reconnecting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
            connect(singBoxPath: params.singBoxPath, singBoxConfig: params.singBoxConfig,
                    xrayPath: params.xrayPath, xrayConfig: params.xrayConfig)
            onReconnect?()
        }
    }

    // MARK: - Connect / Disconnect

    func connect(
        singBoxPath: String, singBoxConfig: String,
        xrayPath: String, xrayConfig: String,
        bypassDomains: [String] = []
    ) {
        guard !isRunning else { return }
        lastConnection = (singBoxPath, singBoxConfig, xrayPath, xrayConfig)

        let tmp = FileManager.default.temporaryDirectory.path
        let hasXray = !xrayConfig.isEmpty && !xrayPath.isEmpty
        let hasSingBox = !singBoxConfig.isEmpty && !singBoxPath.isEmpty

        if hasXray {
            let finalConfig = BypassService.injectXray(xrayConfig, domains: bypassDomains)
            try? finalConfig.write(toFile: "\(tmp)/xray-config.json", atomically: true, encoding: .utf8)
        }
        if hasSingBox {
            let finalConfig = BypassService.injectSingBox(singBoxConfig, domains: bypassDomains)
            try? finalConfig.write(toFile: "\(tmp)/singbox-config.json", atomically: true, encoding: .utf8)
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
        let script = buildScript(tmp: tmp, hasXray: hasXray, hasSingBox: hasSingBox,
                                 xrayPath: xrayPath, singBoxPath: singBoxPath)
        try? script.write(toFile: Self.runScript, atomically: true, encoding: .utf8)

        startLogTail()

        let process = Process()
        if isPasswordless {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["/bin/bash", Self.runScript]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", """
                do shell script "bash '\(Self.runScript)'" with administrator privileges
                """]
        }

        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.stopLogTail()
                self?.logs.append("[Disconnected (exit \(p.terminationStatus))]")
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
        tmp: String, hasXray: Bool, hasSingBox: Bool,
        xrayPath: String, singBoxPath: String
    ) -> String {
        var cmds = ["#!/bin/bash", "cd /tmp", "exec > '\(logFile)' 2>&1"]

        // Kill stale processes from previous session (e.g. after sleep/wake)
        cmds.append("pkill -f 'sing-box run' 2>/dev/null; pkill -f 'xray run' 2>/dev/null; sleep 1")

        if hasXray {
            cmds.append("echo '[xray] starting...'")
            cmds.append("'\(xrayPath)' run -config '\(tmp)/xray-config.json' &")
            cmds.append("XRAY_PID=$!")
            cmds.append("echo '[xray] started pid='$XRAY_PID")
            if hasSingBox { cmds.append("sleep 1") }
        }

        if hasSingBox {
            cmds.append("echo '[sing-box] starting...'")
            cmds.append("'\(singBoxPath)' run -c '\(tmp)/singbox-config.json' &")
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

    func disconnect() {
        guard isRunning else { return }
        logs.append("[Disconnecting...]")
        helperProcess?.terminate()
        helperProcess = nil

        if isPasswordless {
            let script = "#!/bin/bash\npkill -f 'sing-box run' 2>/dev/null\npkill -f 'xray run' 2>/dev/null\n"
            try? script.write(toFile: Self.stopScript, atomically: true, encoding: .utf8)
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            kill.arguments = ["/bin/bash", Self.stopScript]
            try? kill.run()
        } else {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            kill.arguments = ["-e", """
                do shell script "pkill -f 'sing-box run'; pkill -f 'xray run'" with administrator privileges
                """]
            try? kill.run()
        }
        isRunning = false
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
            DispatchQueue.main.async {
                self?.logs.append(contentsOf: lines)
                if let count = self?.logs.count, count > 1000 {
                    self?.logs.removeFirst(count - 1000)
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

    static func findBinary(_ name: String) -> String? {
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

    private static func shellCommand(_ cmd: String) -> String? {
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
}
