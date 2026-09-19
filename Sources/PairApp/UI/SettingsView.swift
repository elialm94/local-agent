import PairCore
import SwiftUI

/// Credentials go to the Keychain; nothing is written to disk in plaintext.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var xai = KeychainStore.read(.xaiAPIKey) ?? ""
    @State private var typesafe = KeychainStore.read(.typesafeAPIKey) ?? ""
    @State private var cursor = KeychainStore.read(.cursorAPIKey) ?? ""
    @State private var agentPath = UserDefaults.standard.string(forKey: "pair.cursorAgentPath") ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("Credentials (stored in macOS Keychain)") {
                SecureField(KeychainStore.Key.xaiAPIKey.title, text: $xai)
                SecureField(KeychainStore.Key.typesafeAPIKey.title, text: $typesafe)
                SecureField(KeychainStore.Key.cursorAPIKey.title, text: $cursor)
                Text("Environment variables XAI_API_KEY / TYPESAFE_API_KEY / CURSOR_API_KEY override these when set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cursor CLI") {
                TextField("Path to `agent` (blank = search PATH and ~/.local/bin)", text: $agentPath)
                Text(model.agentProviderName == "cursor-cli" ? "Cursor CLI detected." : "Cursor CLI not detected — the mock agent is in use. Install with: curl https://cursor.com/install -fsS | bash, then run `agent login`.")
                    .font(.caption).foregroundStyle(model.agentProviderName == "cursor-cli" ? .green : .orange)
            }
            Section("Permissions") {
                permissionRow("Accessibility (global shortcut, reading UI elements)", model.permissions.accessibility)
                permissionRow("Microphone", model.permissions.microphone)
                permissionRow("Screen Recording (visual crops; optional)", model.permissions.screenRecording)
                Button("Request permissions…") { model.requestPermissions() }
            }
            HStack {
                Button("Save & restart assistant") {
                    KeychainStore.write(.xaiAPIKey, value: xai)
                    KeychainStore.write(.typesafeAPIKey, value: typesafe)
                    KeychainStore.write(.cursorAPIKey, value: cursor)
                    UserDefaults.standard.set(agentPath, forKey: "pair.cursorAgentPath")
                    saved = true
                    model.restart()
                }
                .keyboardShortcut(.defaultAction)
                if saved { Text("Saved").foregroundStyle(.green) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear { model.refreshPermissions() }
    }

    private func permissionRow(_ title: String, _ granted: Bool) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(granted ? .green : .red)
            Text(title)
        }
    }
}
