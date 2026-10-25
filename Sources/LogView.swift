import SwiftUI

struct LogView: View {
    var app: AppState
    @State private var level = LogLine.Level.event

    var body: some View {
        let lines = shownLines

        VStack(spacing: 0) {
            HStack {
                Text("Log")
                Spacer()
                Picker("Level", selection: $level) {
                    Text("Errors").tag(LogLine.Level.error)
                    Text("Events").tag(LogLine.Level.event)
                    Text("Everything").tag(LogLine.Level.traffic)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Button {
                    let text = lines.map(\.text).joined(separator: "\n")
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
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 30)
            .padding(.top, 20)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.reversed()) { line in
                        Text(line.text)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 0.5)
                    }
                }
                .padding(10)
            }
            // A grouped Form cannot host the log — it builds all 500 rows at once, its row
            // separators and insets are fixed, and one Text of every line costs ~110 ms per
            // update against ~11 ms here — so these are the Form's metrics copied by hand.
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    // Read only at Everything, so traffic alone does not redraw the page at the other levels.
    private var shownLines: [LogLine] {
        switch level {
        case .error: app.pm.events.filter { $0.level == .error }
        case .event: app.pm.events
        case .traffic: (app.pm.events + app.pm.traffic).sorted { $0.id < $1.id }
        }
    }
}
