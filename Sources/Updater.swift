import CryptoKit
import Foundation

// Updates from the GitHub release feed named in Info.plist. Authenticity is our own ed25519
// signature over the release zip, checked against WVUpdatePublicKey — not Apple's: the app is
// ad-hoc signed. Nothing here runs as root: the new bundle is the user's, like the one it
// replaces, and becomes root's only through the passwordless install at its own prompt.
@Observable
@MainActor
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate, available(String), installing, failed(String)
    }

    var state: State = .idle

    var availableVersion: String? {
        guard case .available(let version) = state else { return nil }
        return version
    }

    nonisolated static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let url: URL

            enum CodingKeys: String, CodingKey {
                case name
                case url = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    private struct Failure: Error {
        let reason: String
    }

    private var release: Release?

    private static let feed = (Bundle.main.object(forInfoDictionaryKey: "WVUpdateFeed") as? String).flatMap(URL.init)
    private static let publicKey = (Bundle.main.object(forInfoDictionaryKey: "WVUpdatePublicKey") as? String)
        .flatMap { Data(base64Encoded: $0) }
        .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }

    // MARK: - Check

    // An automatic check has no one to report to, so its failure leaves the row as it was.
    func check(manual: Bool = false) async {
        guard state != .checking, state != .installing else { return }
        let previous = state
        state = .checking
        do {
            let latest = try await Self.latestRelease()
            release = latest
            state = Self.isNewer(latest.version) ? .available(latest.version) : .upToDate
        } catch {
            state = manual ? .failed(Self.describe(error)) : previous
        }
    }

    // GitHub's releases/latest is the newest release that is neither a draft nor a prerelease.
    private static func latestRelease() async throws -> Release {
        guard let feed else { throw Failure(reason: "No update feed in Info.plist") }
        guard publicKey != nil else { throw Failure(reason: "No update key in Info.plist") }
        let (data, response) = try await URLSession.shared.data(from: feed)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(reason: "The update feed answered HTTP \(status)") }
        guard let release = try? JSONDecoder().decode(Release.self, from: data)
        else { throw Failure(reason: "The update feed is not a GitHub release") }
        return release
    }

    private nonisolated static func isNewer(_ version: String) -> Bool {
        version.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    // MARK: - Install

    // Downloads, verifies and unpacks into $TMPDIR, stages the bundle next to the running one,
    // lets the caller stop the engines, then hands the swap to a shell that outlives this
    // process: it waits for the app to exit, renames the bundles and opens the new one. The
    // engines go down before the swap because the new version's tag cannot stop the old one's
    // sing-box, and a teardown that does not finish — a password dialog left unanswered —
    // cancels the update. True once the shell has the swap: the caller quits the app.
    func install(stopEngines: () async -> Bool) async -> Bool {
        guard let release, let key = Self.publicKey else {
            state = .failed("No update checked")
            return false
        }
        state = .installing
        let bundle = Bundle.main.bundleURL
        let staged = bundle.deletingLastPathComponent().appendingPathComponent(".\(bundle.lastPathComponent).new")
        let aside = bundle.deletingLastPathComponent().appendingPathComponent(".\(bundle.lastPathComponent).old")
        do {
            try await Self.download(release, key: key, into: staged)
        } catch {
            state = .failed(Self.describe(error))
            return false
        }
        guard await stopEngines() else {
            try? FileManager.default.removeItem(at: staged)
            state = .failed("The tunnel did not stop — update cancelled")
            return false
        }
        // Whatever the renames do, "$1" is an app at the end: the new one, or the old one back.
        let script = """
            export PATH=/usr/bin:/bin
            while kill -0 "$4" 2>/dev/null; do sleep 0.2; done
            rm -rf "$3"
            mv "$1" "$3" && { mv "$2" "$1" || mv "$3" "$1"; }
            rm -rf "$2" "$3"
            open -n "$1"
            """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", bundle.path, staged.path, aside.path,
                            String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try helper.run()
        } catch {
            try? FileManager.default.removeItem(at: staged)
            state = .failed(error.localizedDescription)
            return false
        }
        return true
    }

    // The signature is checked over the zip's bytes before anything unpacks it, so ditto only
    // ever sees an archive release.sh made.
    private nonisolated static func download(_ release: Release, key: Curve25519.Signing.PublicKey, into staged: URL) async throws {
        let zipName = "WarpVeil-\(release.version)-macOS.zip"  // release.sh's ZIP_NAME
        guard let zip = release.assets.first(where: { $0.name == zipName }),
              let signatureAsset = release.assets.first(where: { $0.name == zipName + ".sig" })
        else { throw Failure(reason: "Release \(release.version) has no signed \(zipName)") }

        // A path of its own per attempt: Bundle(url:) caches what it read at a path for the life of
        // the process, so a second install from the same path would check the first archive.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("warpveil-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = work.appendingPathComponent(zipName)
        try FileManager.default.moveItem(at: try await fetch(zip.url), to: archive)
        let encoded = try Data(contentsOf: try await fetch(signatureAsset.url))
        guard let signature = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              key.isValidSignature(signature, for: try Data(contentsOf: archive, options: .mappedIfSafe))
        else { throw Failure(reason: "The signature does not match — not installed") }

        let unpacked = work.appendingPathComponent("unpacked")
        try await unzip(archive, into: unpacked)
        let bundle = unpacked.appendingPathComponent("WarpVeil.app")
        try verify(bundle: bundle, version: release.version)
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: bundle, to: staged)
    }

    // A download gets no quarantine attribute: the file is the app's own, not Finder's.
    private nonisolated static func fetch(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(reason: "\(url.lastPathComponent): HTTP \(status)") }
        return file
    }

    // Waited for without holding a thread of the pool.
    private nonisolated static func unzip(_ archive: URL, into directory: URL) async throws {
        let status: Int32 = await withCheckedContinuation { continuation in
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", archive.path, directory.path]
            ditto.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try ditto.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
        guard status == 0 else { throw Failure(reason: "Could not unpack the archive") }
    }

    // What release.sh zipped and nothing else: a real WarpVeil.app with this bundle id, the
    // version the tag names and newer than this one, an arm64 executable. ditto recreates a
    // symlink entry, so the top level has to be a directory of its own.
    private nonisolated static func verify(bundle: URL, version: String) throws {
        let values = try? bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink == false, let new = Bundle(url: bundle)
        else { throw Failure(reason: "The archive holds no app") }
        guard new.bundleIdentifier == Bundle.main.bundleIdentifier
        else { throw Failure(reason: "The app in the archive is not \(Bundle.main.bundleIdentifier ?? "this app")") }
        guard new.infoDictionary?["CFBundleShortVersionString"] as? String == version, isNewer(version)
        else { throw Failure(reason: "The archive is not version \(version), newer than \(currentVersion)") }
        guard new.executableArchitectures?.contains(NSNumber(value: NSBundleExecutableArchitectureARM64)) == true
        else { throw Failure(reason: "The app in the archive is not arm64") }
    }

    private static func describe(_ error: Error) -> String {
        (error as? Failure)?.reason ?? error.localizedDescription
    }
}
