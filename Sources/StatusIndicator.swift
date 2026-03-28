import SwiftUI

struct StatusIndicator: View {
    let isConnected: Bool

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            if isConnected {
                Circle()
                    .stroke(Color.green.opacity(0.4), lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .scaleEffect(isPulsing ? 1.8 : 1.0)
                    .opacity(isPulsing ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: isPulsing)
            }

            Circle()
                .fill(isConnected ? Color.green : Color.gray)
                .frame(width: 12, height: 12)
        }
        .frame(width: 24, height: 24)
        .onAppear { isPulsing = true }
        .onChange(of: isConnected) { isPulsing = isConnected }
    }
}
