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

        Task.detached { [self] in
            let brew = Self.findBrew()
            await MainActor.run {
                if let path = brew {
                    self.brewPath = path
                    self.statuses[.homebrew] = .installed(path)
                } else {
                    self.statuses[.homebrew] = .missing
                }
            }

            let sb = ProcessManager.findBinary("sing-box")
            await MainActor.run {
                if let path = sb {
                    self.singBoxPath = path
                    self.statuses[.singBox] = .installed(path)
                } else {
                    self.statuses[.singBox] = .missing
                }
            }

            let xr = ProcessManager.findBinary("xray")
            await MainActor.run {
                if let path = xr {
                    self.xrayPath = path
                    self.statuses[.xray] = .installed(path)
                } else {
                    self.statuses[.xray] = .missing
                }
            }
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

        Task.detached { [self] in
            // Step 1: Homebrew
            let brewMissing: Bool = await MainActor.run {
                if case .missing = self.statuses[.homebrew] { return true }
                if case .failed = self.statuses[.homebrew] { return true }
                return false
            }
            if brewMissing {
                await self.installHomebrew()
            }

            let brewOK: Bool = await MainActor.run {
                if case .installed = self.statuses[.homebrew] { return true }
                return false
            }
            guard brewOK else {
                await MainActor.run {
                    self.appendLog("[Error] Cannot proceed without Homebrew")
                    self.isInstalling = false
                }
                return
            }

            // Step 2: Packages
            for dep in [Dependency.singBox, Dependency.xray] {
                let needsInstall: Bool = await MainActor.run {
                    let s = self.statuses[dep] ?? .unknown
                    if case .installed = s { return false }
                    return true
                }
                if needsInstall {
                    await self.installFormula(dep)
                }
            }

            await MainActor.run { self.isInstalling = false }
        }
    }

    private func installHomebrew() async {
        await MainActor.run {
            statuses[.homebrew] = .installing
            appendLog("[Homebrew] Installing...")
        }

        let success = await runAndStream(
            "/usr/bin/osascript",
            arguments: ["-e", """
                do shell script "NONINTERACTIVE=1 /bin/bash -c \\\"$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\\\"" with administrator privileges
                """]
        )

        let path = Self.findBrew()
        await MainActor.run {
            if success, let path {
                brewPath = path
                statuses[.homebrew] = .installed(path)
                appendLog("[Homebrew] Installed at \(path)")
            } else {
                statuses[.homebrew] = .failed("Installation failed")
                appendLog("[Homebrew] Installation failed. Install manually: https://brew.sh")
            }
        }
    }

    private func installFormula(_ dep: Dependency) async {
        guard let formula = dep.formulaName else { return }
        let brew = await MainActor.run { brewPath ?? "/opt/homebrew/bin/brew" }

        await MainActor.run {
            statuses[dep] = .installing
            appendLog("[\(dep.rawValue)] Installing via Homebrew...")
        }

        let success = await runAndStream(brew, arguments: ["install", formula])
        let resolved = ProcessManager.findBinary(formula)

        await MainActor.run {
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
    }

    // MARK: - Process runner with real-time log streaming

    private func runAndStream(_ path: String, arguments: [String]) async -> Bool {
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
                DispatchQueue.main.async {
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
                DispatchQueue.main.async { [weak self] in
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
