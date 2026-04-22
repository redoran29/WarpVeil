import Foundation

enum Dependency: String, CaseIterable, Identifiable {
    case singBox = "sing-box"
    case xray    = "xray"

    var id: String { rawValue }
}

enum DependencyStatus: Equatable {
    case unknown
    case checking
    case installed(String)
    case missing
}

@Observable
@MainActor
final class SetupService {
    var statuses: [Dependency: DependencyStatus] = [:]
    var versions: [Dependency: String] = [:]
    var singBoxPath: String?
    var xrayPath: String?

    func checkAll() {
        for dep in Dependency.allCases {
            statuses[dep] = .checking
        }

        Task {
            let sb = await Task.detached { ProcessManager.findBinary("sing-box") }.value
            singBoxPath = sb
            statuses[.singBox] = sb.map { .installed($0) } ?? .missing

            let xr = await Task.detached { ProcessManager.findBinary("xray") }.value
            xrayPath = xr
            statuses[.xray] = xr.map { .installed($0) } ?? .missing

            if let sb {
                versions[.singBox] = await Task.detached { Self.binaryVersion(sb, arg: "version") }.value
            }
            if let xr {
                versions[.xray] = await Task.detached { Self.binaryVersion(xr, arg: "version") }.value
            }
        }
    }

    private nonisolated static func binaryVersion(_ path: String, arg: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [arg]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch { return nil }
        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        return output.components(separatedBy: .newlines).first { !$0.isEmpty }
    }
}
