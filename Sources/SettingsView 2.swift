import SwiftUI

struct SettingsView: View {
    var pm: ProcessManager
    @AppStorage("xrayConfig") private var xrayConfig = ""
    @AppStorage("singBoxConfig") private var singBoxConfig = ""
    @AppStorage("xrayPath") private var xrayPath = ""
    @AppStorage("singBoxPath") private var singBoxPath = ""
    @State private var selectedEngine: ConfigEngine = .singBox

    enum ConfigEngine: String, CaseIterable {
        case singBox = "sing-box"
        case xray = "Xray"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Binary Paths") {
                    LabeledContent("sing-box") {
                        TextField("path", text: $singBoxPath)
                            .font(.system(size: 11, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("xray") {
                        TextField("path", text: $xrayPath)
                            .font(.system(size: 11, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section("Passwordless Mode") {
                    HStack {
                        if pm.isPasswordless {
                            Label("Enabled", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Disable") { pm.removePasswordless() }
                                .controlSize(.small)
                        } else {
                            Label("Disabled", systemImage: "lock.shield")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Enable") { pm.installPasswordless() }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 170)

            Divider()

            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $selectedEngine) {
                        ForEach(ConfigEngine.allCases, id: \.self) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                TextEditor(text: selectedEngine == .singBox ? $singBoxConfig : $xrayConfig)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
            }

            Divider()

            HStack {
                Spacer()
                Button("Quit WarpVeil") {
                    if pm.isRunning { pm.disconnect() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApplication.shared.terminate(nil)
                    }
                }
                .keyboardShortcut("q")
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
