import Foundation

// Every server runs on xray now. sing-box stays a case because files written by earlier builds
// carry it, and a stored manual config of that kind is refused at connect, not lost at load.
enum Engine: String, Codable {
    case singBox = "sing-box"
    case xray = "xray"
}

struct Server: Codable, Identifiable {
    // An opaque key, minted the first time a server is seen and carried across refreshes by
    // store(). Never derived from the fields: every formula so far broke the moment one site
    // spelled a field differently, and the stored selection had to be migrated each time.
    var id = UUID().uuidString
    var name: String
    var protocolType: String
    var address: String
    var transport: String
    var config: String
    var engine: Engine?

    // Identity is the endpoint, not the label. Panels put remaining traffic and expiry dates
    // in node names, so a name in here would re-key every server on every refresh — the very
    // failure the stored key exists to prevent. A transport the file never stored matches any:
    // the field is younger than the file.
    func isSameNode(as other: Server) -> Bool {
        protocolType == other.protocolType && address == other.address
            && (transport.isEmpty || other.transport.isEmpty || transport == other.transport)
    }
}

// Files from builds up to 1.2 carry an id per server and no transport; later builds wrote the
// reverse. Declared in an extension so the memberwise init the parsers use survives.
extension Server {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedID = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        id = storedID.isEmpty ? UUID().uuidString : storedID
        name = try c.decode(String.self, forKey: .name)
        protocolType = try c.decode(String.self, forKey: .protocolType)
        address = try c.decode(String.self, forKey: .address)
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? ""
        config = try c.decode(String.self, forKey: .config)
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine)
    }
}

struct Subscription: Codable, Identifiable {
    let id: UUID
    var name: String
    var url: String
    var isManual: Bool = false
    var engine: Engine = .xray
    var servers: [Server]
    var lastUpdated: Date?

    init(name: String, url: String = "", isManual: Bool = false, engine: Engine = .xray) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.isManual = isManual
        self.engine = engine
        self.servers = []
        self.lastUpdated = nil
    }
}

struct LogLine: Identifiable {
    enum Level { case error, event, traffic }

    let id: Int
    let level: Level
    let text: String

    // An engine line's level is its own: sing-box writes `ERROR`, `WARN`, `INFO` first, xray
    // `[Error]`, `[Warning]`, `[Info]` after its timestamp and an access line per connection,
    // run.sh `[error]`. Unmarked failures are known by their start: xray's `Failed to start`, a Go
    // crash, sudo's and bash's own errors. Traffic is only what says it is info, debug or access:
    // any other line — the rest of a crash trace among them — is an event. An engine bump
    // re-checks this against its output.
    static func engineLevel(of text: String) -> Level {
        let afterTimestamp = xrayBody(of: text)
        if errorStarts.contains(where: text.hasPrefix) || text.contains("/run.sh: line ")
            || afterTimestamp?.hasPrefix("[Error]") == true { return .error }
        if ["INFO", "DEBUG", "TRACE"].contains(where: text.hasPrefix) { return .traffic }
        guard let afterTimestamp else { return .event }
        let isAccess = afterTimestamp.hasPrefix("from ")
            && (afterTimestamp.contains(" accepted ") || afterTimestamp.contains(" rejected "))
        return isAccess || afterTimestamp.hasPrefix("[Info]") || afterTimestamp.hasPrefix("[Debug]") ? .traffic : .event
    }

    private static let errorStarts = [
        "ERROR", "FATAL", "PANIC", "panic: ", "fatal error: ", "Failed to start", "sudo: ", "[error]",
    ]

    // xray's lines start "2026/10/25 16:25:51.925813 ".
    private static func xrayBody(of text: String) -> Substring? {
        let parts = text.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, parts[0].count == 10, parts[0].filter({ $0 == "/" }).count == 2 else { return nil }
        return parts[2]
    }
}
