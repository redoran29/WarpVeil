import SwiftUI

extension Color {
    static let lavender = Color(red: 0.62, green: 0.56, blue: 0.85)
}

enum Page: String, CaseIterable {
    case connection = "Connection"
    case routing = "Routing"
    case advanced = "Advanced"
    case logs = "Logs"

    var icon: String {
        switch self {
        case .connection: "power"
        case .routing: "arrow.triangle.branch"
        case .advanced: "gearshape"
        case .logs: "doc.text"
        }
    }
}

struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    // The measured view has two children — the content and the transparent measuring
    // background — so an overwriting reduce lets the background's zero win.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ContentView: View {
    var app: AppState
    var onHeightChange: @MainActor (CGFloat) -> Void

    @State private var page: Page = .connection

    var body: some View {
        VStack(spacing: 0) {
            PageTabBar(selection: $page)

            Divider()

            // One cap for every page: an uncapped page measures its full content height and
            // the window would grow past the screen.
            pageView
                .frame(maxHeight: 700)
        }
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            Task { @MainActor in onHeightChange(height) }
        }
        // Pins the content to the title bar while the window animates underneath it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var pageView: some View {
        switch page {
        case .connection:
            ConnectionView(app: app)
        case .routing:
            RoutingView(app: app)
        case .advanced:
            AdvancedView(app: app)
        case .logs:
            LogView(app: app)
        }
    }
}

private struct PageTabBar: View {
    @Binding var selection: Page

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Page.allCases, id: \.self) { page in
                Button {
                    selection = page
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: page.icon)
                            .font(.system(size: 17))
                        Text(page.rawValue)
                            .font(.system(size: 11))
                    }
                    .frame(width: 72, height: 52)
                    .foregroundStyle(selection == page ? .primary : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selection == page ? Color.secondary.opacity(0.15) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}
