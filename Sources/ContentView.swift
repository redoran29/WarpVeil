import SwiftUI

extension Color {
    static let lavender = Color(red: 0.62, green: 0.56, blue: 0.85)
}

enum Page: String, CaseIterable {
    case servers = "Servers"
    case routing = "Routing"
    case advanced = "Advanced"
    case logs = "Logs"

    var icon: String {
        switch self {
        case .servers: "server.rack"
        case .routing: "arrow.triangle.branch"
        case .advanced: "gearshape"
        case .logs: "doc.text"
        }
    }
}

struct ContentView: View {
    var app: AppState

    @State private var page: Page = .servers

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(Page.allCases, id: \.self) { page in
                    Label(page.rawValue, systemImage: page.icon).tag(page)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } content: {
            pageView
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            ConnectionView(app: app)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
        }
        .frame(minHeight: 480)
    }

    @ViewBuilder
    private var pageView: some View {
        switch page {
        case .servers: ServersView(app: app)
        case .routing: RoutingView(app: app)
        case .advanced: AdvancedView(app: app)
        case .logs: LogView(app: app)
        }
    }
}
