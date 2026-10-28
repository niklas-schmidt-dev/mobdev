import MobdevCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › App Store Connect: the API key, a check that it works, and whether agents may change
/// anything. The private key is read from the .p8 file once and never shown.
struct AppStoreSettings: View {
    @Environment(AppModel.self) private var model
    @State private var issuerID = ""
    @State private var keyID = ""
    @State private var privateKey: String?
    @State private var keyFileName: String?
    @State private var importing = false
    @State private var failure: String?
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var confirmRemove = false

    private var appStore: AppStoreModel { model.appStore }

    var body: some View {
        Form {
            if let storedKeyID = appStore.keyID {
                Section {
                    LabeledContent("Key ID", value: storedKeyID)
                    LabeledContent("Issuer ID") {
                        Text(appStore.issuerID ?? "").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("Private key", value: "Stored on this Mac")
                    HStack {
                        Button("Test Connection") { test() }.disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Remove Key…", role: .destructive) { confirmRemove = true }
                    }
                    if let testResult {
                        Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(testResult.ok ? .green : .red)
                            .font(.callout)
                    }
                } header: {
                    Text("API key")
                } footer: {
                    Text("The private key is kept in a file only you can read. Agents and the relay get answers from App Store Connect, never the key.")
                }
            } else {
                Section {
                    TextField("Issuer ID", text: $issuerID, prompt: Text("57246542-96fe-1a63-e053-0824d011072a"))
                    TextField("Key ID", text: $keyID, prompt: Text("2X9R4HXF34"))
                    LabeledContent("Private key") {
                        HStack {
                            Text(keyFileName ?? "No file chosen").foregroundStyle(.secondary).lineLimit(1)
                            Button("Choose…") { importing = true }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Save Key") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(issuerID.isEmpty || keyID.isEmpty || privateKey == nil)
                    }
                    if let failure {
                        Text(failure).font(.callout).foregroundStyle(.red)
                    }
                } header: {
                    Text("API key")
                } footer: {
                    Text(
                        "Create a team key in App Store Connect › Users and Access › Integrations › App Store Connect API, with the App Manager role, which allows everything Mobdev does. Download its AuthKey_….p8 file, which Apple offers once, and copy the issuer ID shown above the keys."
                    )
                }
            }

            Section {
                Toggle(
                    "Agents may change App Store Connect",
                    isOn: Binding(get: { model.settings.appStoreAgentChanges }, set: { model.setAppStoreAgentChanges($0) }))
            } footer: {
                Text(
                    "Agents can always read apps, builds, TestFlight groups, versions and reviews. With this on, they may also add builds to TestFlight groups, set What to Test and reply to reviews, which testers and customers see. In Mobdev you confirm each change yourself."
                )
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]) { result in
            choose(result)
        }
        .confirmationDialog("Remove the App Store Connect key?", isPresented: $confirmRemove) {
            Button("Remove Key", role: .destructive) { remove() }
        } message: {
            Text("Mobdev and agents can no longer reach App Store Connect until you add a key again. The key stays valid in App Store Connect; revoke it there if you no longer need it.")
        }
    }

    private func choose(_ result: Result<URL, Error>) {
        failure = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            privateKey = try String(contentsOf: url, encoding: .utf8)
            keyFileName = url.lastPathComponent
            if keyID.isEmpty, let id = AppStoreCredentials.keyID(fromFileName: url.lastPathComponent) { keyID = id }
        } catch {
            failure = "Could not read the file: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let privateKey else { return }
        do {
            try appStore.saveKey(issuerID: issuerID, keyID: keyID, privateKey: privateKey)
            // The key lives in its file now, not in this view.
            self.privateKey = nil
            keyFileName = nil
            issuerID = ""
            keyID = ""
            failure = nil
            test()
        } catch {
            failure = String(describing: error)
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            testResult = await appStore.testConnection()
            testing = false
        }
    }

    private func remove() {
        do {
            try appStore.removeKey()
            testResult = nil
        } catch {
            testResult = (false, "Could not remove the key: \(error.localizedDescription)")
        }
    }
}
