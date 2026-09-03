import Foundation

enum Engine: String, Codable, CaseIterable {
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
    var engine: Engine = .singBox
    var servers: [Server]
    var lastUpdated: Date?

    init(name: String, url: String = "", isManual: Bool = false, engine: Engine = .singBox) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.isManual = isManual
        self.engine = engine
        self.servers = []
        self.lastUpdated = nil
    }
}
