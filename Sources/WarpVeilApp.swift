import SwiftUI

@main
struct WarpVeilApp: App {
    @State private var pm = ProcessManager()
    @State private var loc = LocationService()
    @State private var net = NetworkMonitor()
    @State private var setup = SetupService()

    var body: some Scene {
        MenuBarExtra {
            ContentView(pm: pm, loc: loc, net: net, setup: setup)
                .frame(width: 420, height: 500)
        } label: {
            Image(systemName: pm.isRunning ? "checkmark.shield.fill" : "shield.slash")
                .symbolEffect(.bounce, value: pm.isRunning)
            if pm.isRunning && !net.downloadSpeed.isEmpty {
                Text("\(loc.flag) ↓\(net.downloadSpeed) ↑\(net.uploadSpeed)")
                    .font(.system(size: 12, design: .monospaced))
            } else if !loc.flag.isEmpty {
                Text(loc.flag)
            }
        }
        .menuBarExtraStyle(.window)
        .onChange(of: pm.isRunning) {
            if pm.isRunning {
                net.start()
            } else {
                net.stop()
            }
        }
    }
}
