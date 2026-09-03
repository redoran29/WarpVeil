import Foundation

enum Engine: String, Codable, CaseIterable {
    case singBox = "sing-box"
    case xray = "xray"
}

struct Server: Codable, Identifiable {
    var name: String
    var protocolType: String
    var address: String
    var config: String
    var engine: Engine?

    // Derived, not stored: refreshing a subscription rebuilds every Server, and a fresh UUID
    // each time would drop the user's selection and the measured pings on every launch.
    var id: String { "\(protocolType)|\(address)|\(name)" }
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
