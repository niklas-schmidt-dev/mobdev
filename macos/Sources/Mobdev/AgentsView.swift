import MobdevCore
import SwiftUI

struct AgentsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                CodeRow(
                    title: "Claude Code", subtitle: "Run once in Terminal. Available in every project.",
                    symbol: "terminal", code: model.claudeCodeCommand)
                CodeRow(
                    title: "Codex", subtitle: "Add to ~/.codex/config.toml.",
                    symbol: "chevron.left.forwardslash.chevron.right", code: model.codexConfig)
                CodeRow(
                    title: "Claude Desktop, Cursor and others", subtitle: "Add to the app's mcpServers config.",
                    symbol: "macwindow", code: model.jsonConfig)
            } header: {
                Text("MCP")
            } footer: {
                Text("These configs need no secret. Mobdev reads its token locally and starts in the background when an agent calls it.")
            }

            Section {
                CodeRow(
                    title: "Streamable HTTP", subtitle: model.localMCPURL, symbol: "link", code: model.httpCommand,
                    secrets: [model.token])
                CodeRow(
                    title: "REST API", subtitle: "Screenshots, taps and text as plain HTTP.",
                    symbol: "curlybraces", code: model.curlCommand, secrets: [model.token])
            } header: {
                Text("HTTP")
            } footer: {
                Text("Only this Mac can connect, and every request needs the token from Settings › API.")
            }

            Section("Server") {
                LabeledContent("Status") {
                    Label(model.serverSummary, systemImage: model.serverFailed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.serverFailed ? .red : .green)
                }
                LabeledContent("Tools") {
                    Text(PhoneTools.definitions.map(\.name).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connect Agents")
        .navigationSubtitle("MCP and HTTP on this Mac")
    }
}
