import Foundation

/// `list_secrets`: the names of the secrets the user stored. They belong to the Mac, not to a
/// device, so the tool works without one, like the project tools.
enum SecretTools {
    static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "list_secrets", title: "List secrets",
            description:
                "Names of the secrets type_secret can type, such as a test account's password, and whether agents through a relay may type them. Values are never shown. The user adds secrets in Mobdev's Settings › Secrets or with `Mobdev secret set <name>`.",
            inputSchema: PhoneTools.schema([:], screenshot: false), readOnly: true)
    ]

    static func isSecretTool(_ name: String) -> Bool { definitions.contains { $0.name == name } }

    static func call(_ name: String) -> ToolOutput {
        let secrets = TypedSecrets.list()
        guard !secrets.isEmpty else {
            return ToolOutput(
                text: "No secrets yet. Ask the user to add one in Mobdev's Settings › Secrets, or with `Mobdev secret set <name>`.",
                data: .array([]))
        }
        return ToolOutput(
            text: secrets.map { "\($0.name)\($0.relay ? "" : " (this Mac only)")" }.joined(separator: "\n"),
            data: .array(secrets.map { ["name": .string($0.name), "relay": .bool($0.relay)] }))
    }
}

/// `type_secret`: types a secret the user stored, so its value never reaches the agent, a flow file
/// or the activity log.
extension PhoneTools {
    static let secretDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "type_secret", title: "Type secret",
            description:
                "Type a stored secret, such as a test account's password, into the focused field without seeing it. Names come from list_secrets. Tap the field first; submit presses Return. Use it instead of type_text for anything secret: recorded flows and tests keep only the name.",
            inputSchema: schema(
                [
                    "name": ["type": "string"],
                    "submit": ["type": "boolean", "description": "Press Return after typing"],
                ], required: ["name"]),
            readOnly: false)
    ]

    func typeSecret(_ args: Arguments, source: String) async throws -> ToolOutput {
        let name = try args.string("name")
        guard let entry = TypedSecrets.entry(name) else {
            let names = TypedSecrets.list().map(\.name)
            throw ToolFailure(
                "No secret \"\(name)\". \(names.isEmpty ? "There are none yet" : "Secrets: \(names.joined(separator: ", "))"). The user adds them in Mobdev's Settings › Secrets or with `Mobdev secret set <name>`.")
        }
        guard source != "relay" || entry.relay else {
            throw ToolFailure(
                "The secret \"\(name)\" is for agents on this Mac only. The user can allow it through the relay in Settings › Secrets.")
        }
        let submit = args.bool("submit") == true
        try requireTouch()
        do {
            if try await phone.typeText(entry.value) {
                if submit { try await phone.press(KeyStroke(0x28)) }
            } else {
                var strokes = try phone.status().keyboardLayout.strokes(typing: entry.value)
                if submit { strokes.append(KeyStroke(0x28)) }
                try await phone.type(strokes)
            }
        } catch is KeyboardError, is DeveloperError {
            // These can quote the character that failed, which is part of the secret.
            throw ToolFailure("Could not type the secret \"\(name)\": it has a character this device cannot type.")
        }
        return ToolOutput(text: "Typed the secret \"\(name)\"\(submit ? " and pressed Return" : "").")
    }
}
