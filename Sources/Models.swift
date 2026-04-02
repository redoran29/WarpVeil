import Foundation

enum Engine: String, Codable, CaseIterable {
    case singBox = "sing-box"
    case xray = "xray"
}

struct Server: Codable, Identifiable {
    let id: UUID
    var name: String
    var protocolType: String
    var address: String
    var config: String
    var engine: Engine?

    init(name: String, protocolType: String, address: String, config: String, engine: Engine? = nil) {
        self.id = UUID()
        self.name = name
        self.protocolType = protocolType
        self.address = address
        self.config = config
        self.engine = engine
    }
}

struct Subscription: Codable, Identifiable {
    let id: UUID
    var name: String
    var url: String
    var isManual: Bool
    var engine: Engine
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
