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
    @AppStorage("sidebarExpanded") private var sidebarExpanded = false

    var body: some View {
        NavigationSplitView {
            SidebarRail(selection: $page, isExpanded: $sidebarExpanded)
                // The rail carries its own expand control; the built-in one would be a
                // second, differently-behaving toggle next to it.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(sidebarExpanded ? 180 : 60)
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

private struct SidebarRail: View {
    @Binding var selection: Page
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "arrow.left" : "arrow.right")
                    .font(.system(size: 15))
                    .frame(width: 24, height: 34)
                    .padding(.leading, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)

            ForEach(Page.allCases, id: \.self) { page in
                Button {
                    selection = page
                } label: {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(selection == page ? Color.lavender : .clear)
                            .frame(width: 3, height: 20)

                        HStack(spacing: 10) {
                            Image(systemName: page.icon)
                                .font(.system(size: 15))
                                .frame(width: 24)
                            if isExpanded {
                                Text(page.rawValue).font(.system(size: 13))
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selection == page ? Color.secondary.opacity(0.14) : .clear)
                        )
                        .padding(.leading, 5)
                        .padding(.trailing, 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == page ? .primary : .secondary)
                .help(page.rawValue)
            }

            Spacer()
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
