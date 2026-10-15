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
    private var lastAnswered: Date?
    private var checkGeneration = 0

    private static let feed = (Bundle.main.object(forInfoDictionaryKey: "WVUpdateFeed") as? String).flatMap(URL.init)
    private static let publicKey = (Bundle.main.object(forInfoDictionaryKey: "WVUpdatePublicKey") as? String)
        .flatMap { Data(base64Encoded: $0) }
        .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }

    // MARK: - Check

    // Asked hourly: a day after the last check that got an answer, so a failed one — offline
    // right after a wake — is tried again within the hour instead of the next day.
    func checkIfDue() async {
        if let lastAnswered, Date().timeIntervalSince(lastAnswered) < 24 * 3600 { return }
        await check()
    }

    // An automatic check has no one to report to, so its failure leaves the row as it was. A
    // status menu built before the check began still offers the update, and an install started
    // from it owns the state from then on — a check that comes back after that, or after a
    // newer check began, writes nothing.
    func check(manual: Bool = false) async {
        guard state != .checking, state != .installing else { return }
        checkGeneration += 1
        let generation = checkGeneration
        let previous = state
        state = .checking
        do {
            let latest = try await Self.latestRelease()
            lastAnswered = Date()
            guard generation == checkGeneration, state == .checking else { return }
            release = latest
            state = Self.isNewer(latest.version) ? .available(latest.version) : .upToDate
        } catch {
            guard generation == checkGeneration, state == .checking else { return }
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

    // Downloads, verifies and unpacks into $TMPDIR, lets the caller stop the engines, stages the
    // bundle next to the running one, then hands the swap to a shell that outlives this
    // process: it waits for the app to exit, renames the bundles and opens the new one. The
    // engines go down before the swap because the new version's tag cannot stop the old one's
    // sing-box, and a teardown that does not finish — a password dialog left unanswered —
    // cancels the update. True once the shell has the swap: the caller quits the app.
    func install(stopEngines: () async -> Bool) async -> Bool {
        // A second install would share the staging path and race the first one's swap.
        guard state != .installing else { return false }
        guard let release, let key = Self.publicKey else {
            state = .failed("No update checked")
            return false
        }
        let bundle = Bundle.main.bundleURL
        let directory = bundle.deletingLastPathComponent()
        // Staging comes after the engines stop, so a directory the swap cannot write — a standard
        // user's /Applications, App Translocation's read-only mount — is caught before them.
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            state = .failed("Cannot replace the app in \(directory.path) — move WarpVeil to a folder you can write")
            return false
        }
        state = .installing
        let staged = directory.appendingPathComponent(".\(bundle.lastPathComponent).new")
        let aside = directory.appendingPathComponent(".\(bundle.lastPathComponent).old")
        // A path of its own per attempt: Bundle(url:) caches what it read at a path for the life of
        // the process, so a second install from the same path would check the first archive.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("warpveil-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let verified: URL
        do {
            verified = try await Self.download(release, key: key, into: work)
        } catch {
            state = .failed(Self.describe(error))
            return false
        }
        guard await stopEngines() else {
            state = .failed("The tunnel did not stop — update cancelled")
            return false
        }
        // Staged only now: an app quit while the engines stop leaves nothing next to the bundle.
        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: verified, to: staged)
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
        // "$1" ends as the new app or the old one back. Only then do the other copies go: if a
        // rollback failed too, both stay where they are rather than nowhere.
        let script = """
            export PATH=/usr/bin:/bin
            while kill -0 "$4" 2>/dev/null; do sleep 0.2; done
            rm -rf "$3"
            mv "$1" "$3" && { mv "$2" "$1" || mv "$3" "$1"; }
            [ -d "$1" ] && rm -rf "$2" "$3"
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

    // The verified app, unpacked in `work`. The signature is checked over the zip's bytes before
    // anything unpacks it, so ditto only ever sees an archive release.sh made.
    private nonisolated static func download(_ release: Release, key: Curve25519.Signing.PublicKey, into work: URL) async throws -> URL {
        let zipName = "WarpVeil-\(release.version)-macOS.zip"  // release.sh's ZIP_NAME
        guard let zip = release.assets.first(where: { $0.name == zipName }),
              let signatureAsset = release.assets.first(where: { $0.name == zipName + ".sig" })
        else { throw Failure(reason: "Release \(release.version) has no signed \(zipName)") }

        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])

        let archive = work.appendingPathComponent(zipName)
        try FileManager.default.moveItem(at: try await fetch(zip.url), to: archive)
        let (encoded, response) = try await URLSession.shared.data(from: signatureAsset.url)
        try requireOK(response, from: signatureAsset.url)
        guard let signature = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              key.isValidSignature(signature, for: try Data(contentsOf: archive, options: .mappedIfSafe))
        else { throw Failure(reason: "The signature does not match — not installed") }

        let unpacked = work.appendingPathComponent("unpacked")
        try await unzip(archive, into: unpacked)
        let bundle = unpacked.appendingPathComponent("WarpVeil.app")
        try verify(bundle: bundle, version: release.version)
        return bundle
    }

    // A download gets no quarantine attribute: the file is the app's own, not Finder's. The async
    // download leaves its file to the caller, an error page included.
    private nonisolated static func fetch(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        do {
            try requireOK(response, from: url)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }

    private nonisolated static func requireOK(_ response: URLResponse, from url: URL) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(reason: "\(url.lastPathComponent): HTTP \(status)") }
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
