import SwiftUI

enum Tab: String, CaseIterable {
    case servers = "Servers"
    case settings = "Settings"
}

struct ContentView: View {
    var app: AppState

    @State private var tab: Tab = .servers

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider()

            Group {
                switch tab {
                case .servers:
                    ServersView(app: app)
                case .settings:
                    SettingsView(app: app)
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: tab)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                VStack(spacing: 0) {
                    Text(t.rawValue)
                        .font(.system(size: 14, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? .primary : .secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle()
                        .fill(tab == t ? Color.indigo : .clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
                .background(tab == t ? Color.secondary.opacity(0.08) : .clear)
                .onTapGesture { tab = t }
            }
        }
        .frame(height: 40)
    }
}
