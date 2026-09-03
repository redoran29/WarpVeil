import SwiftUI

struct LogView: View {
    var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    let text = app.pm.logs.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy")

                Button {
                    app.pm.clearLogs()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(app.pm.logs.indices.reversed(), id: \.self) { index in
                        Text(app.pm.logs[index])
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 0.5)
                    }
                }
                .padding(8)
            }
        }
    }
}
