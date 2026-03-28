import Foundation

enum Dependency: String, CaseIterable, Identifiable {
    case homebrew = "Homebrew"
    case singBox  = "sing-box"
    case xray     = "xray"

    var id: String { rawValue }

    var formulaName: String? {
        switch self {
        case .homebrew: return nil
        case .singBox:  return "sing-box"
        case .xray:     return "xray"
        }
    }
}

enum DependencyStatus: Equatable {
    case unknown
    case checking
    case installed(String)
    case missing
    case installing
    case failed(String)
}

@Observable
@MainActor
final class SetupService {
    var statuses: [Dependency: DependencyStatus] = [:]
    var logs: [String] = []
    var isInstalling = false
    var singBoxPath: String?
    var xrayPath: String?

    var allInstalled: Bool {
        Dependency.allCases.allSatisfy {
            if case .installed = statuses[$0] { return true }
            return false
        }
    }

    var hasMissing: Bool {
        Dependency.allCases.contains {
            if case .missing = statuses[$0] { return true }
            if case .failed = statuses[$0] { return true }
            return false
        }
    }

    private var brewPath: String?

    // MARK: - Detection

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

    private static func findBrew() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Installation

    func installAll() {
        guard !isInstalling else { return }
        isInstalling = true
        logs.removeAll()

        Task {
            // Step 1: Homebrew
            let brewMissing: Bool = {
                if case .missing = statuses[.homebrew] { return true }
                if case .failed = statuses[.homebrew] { return true }
                return false
            }()
            if brewMissing {
                await installHomebrew()
            }

            let brewOK: Bool = {
                if case .installed = statuses[.homebrew] { return true }
                return false
            }()
            guard brewOK else {
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

    private func installFormula(_ dep: Dependency) async {
        guard let formula = dep.formulaName else { return }
        let brew = brewPath ?? "/opt/homebrew/bin/brew"

        statuses[dep] = .installing
        appendLog("[\(dep.rawValue)] Installing via Homebrew...")

        let success = await runAndStream(brew, arguments: ["install", formula])
        let resolved = await Task.detached { ProcessManager.findBinary(formula) }.value

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

    // MARK: - Process runner with real-time log streaming

    private nonisolated func runAndStream(_ path: String, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                Task { @MainActor in
                    self?.logs.append(contentsOf: lines)
                    if let count = self?.logs.count, count > 2000 {
                        self?.logs.removeFirst(count - 2000)
                    }
                }
            }

            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: p.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                Task { @MainActor [weak self] in
                    self?.appendLog("[Error] \(error.localizedDescription)")
                }
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    private func appendLog(_ line: String) {
        logs.append(line)
    }
}
