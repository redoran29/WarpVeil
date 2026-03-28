import SwiftUI

struct SetupView: View {
    var setup: SetupService

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                ForEach(Dependency.allCases) { dep in
                    HStack {
                        depStatusIcon(setup.statuses[dep] ?? .unknown)
                        Text(dep.rawValue)
                            .font(.system(.body, weight: .medium))
                        Spacer()
                        depStatusLabel(setup.statuses[dep] ?? .unknown)
                    }
                }
            }
            .padding(12)

            Divider()

            HStack {
                Button("Check Again") { setup.checkAll() }
                    .controlSize(.small)
                    .disabled(setup.isInstalling)
                Spacer()
                if setup.allInstalled {
                    Label("All installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Button("Install Missing") { setup.installAll() }
                        .buttonStyle(.borderedProminent)
                        .disabled(setup.isInstalling || !setup.hasMissing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Installation Log").font(.caption).fontWeight(.medium)
                    Spacer()
                    if setup.isInstalling { ProgressView().scaleEffect(0.6) }
                    Button("Clear") { setup.logs.removeAll() }.controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(setup.logs.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 0.5)
                                    .id(i)
                            }
                        }
                        .padding(6)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: setup.logs.count) {
                        if let last = setup.logs.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func depStatusIcon(_ status: DependencyStatus) -> some View {
        switch status {
        case .unknown, .checking:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .installing:
            ProgressView().scaleEffect(0.5)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func depStatusLabel(_ status: DependencyStatus) -> some View {
        switch status {
        case .unknown:
            Text("Not checked").font(.caption).foregroundStyle(.secondary)
        case .checking:
            Text("Checking...").font(.caption).foregroundStyle(.secondary)
        case .installed(let path):
            Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        case .missing:
            Text("Not found").font(.caption).foregroundStyle(.red)
        case .installing:
            Text("Installing...").font(.caption).foregroundStyle(.blue)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.orange).lineLimit(1)
        }
    }
}
