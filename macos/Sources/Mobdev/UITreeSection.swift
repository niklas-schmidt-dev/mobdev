import MobdevCore
import SwiftUI

/// The UI tree for one iPhone, in its info: Mobdev builds Mobdev Runner with Xcode, signs it with
/// the chosen team and keeps it running on the phone, so ui_tree, tap_element and wait_for_element
/// work there as on simulators.
struct UITreeSection: View {
    @Environment(AppModel.self) private var model
    let state: DeviceState
    /// The teams with an Apple Development certificate on this Mac; nil while they are read.
    @State private var teams: [DevelopmentTeam]?

    private var udid: String? { state.info?.id }
    private var isOn: Bool { udid.map { model.settings.runnerDevices.contains($0) } ?? false }

    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    if state.runner == .building || state.runner == .starting { ProgressView().controlSize(.small) }
                    Text(statusText).foregroundStyle(.secondary)
                }
            }
            if isOn, case .failed(let reason) = state.runner {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            team.disabled(isOn)
            HStack {
                if isOn {
                    if case .failed = state.runner { Button("Try Again") { model.restartUITree(state.id) } }
                    Button("Turn Off") { model.setUITree(false, for: state.id) }
                } else {
                    Button("Turn On") { model.setUITree(true, for: state.id) }
                        .buttonStyle(.glassProminent)
                        .disabled(udid == nil || !UIRunner.isTeamID(model.settings.runnerTeam))
                }
            }
        } header: {
            Text("UI Tree")
        } footer: {
            Text(
                "Lets agents find buttons and fields by identifier or label (ui_tree, tap_element). \(MobdevPaths.appName) builds Mobdev Runner, a small UI test, with Xcode, signs it with your team and keeps it running on the iPhone. Needs Developer Mode on the iPhone; the first build takes a minute or two."
            )
        }
        .task {
            let found = await Task.detached { DevelopmentTeam.inKeychain() }.value
            teams = found
            if model.settings.runnerTeam.isEmpty, let first = found.first { model.setRunnerTeam(first.id) }
        }
    }

    private var statusText: String {
        guard isOn else { return "Off" }
        switch state.runner ?? .off {
        case .off: return state.onUSB ? "Starting…" : "Starts when the iPhone is connected"
        case let other: return other.summary
        }
    }

    /// A menu of the teams found, or a field for the team ID when none is.
    @ViewBuilder private var team: some View {
        let selection = Binding(get: { model.settings.runnerTeam }, set: { model.setRunnerTeam($0) })
        if let teams, !teams.isEmpty {
            Picker("Team", selection: selection) {
                ForEach(teams) { Text("\($0.name) (\($0.id))").tag($0.id) }
                if !teams.contains(where: { $0.id == model.settings.runnerTeam }) {
                    Text(model.settings.runnerTeam.isEmpty ? "None" : model.settings.runnerTeam).tag(model.settings.runnerTeam)
                }
            }
        } else if teams != nil {
            TextField("Team ID", text: selection, prompt: Text("ABCDE12345"))
                .help("No Apple Development certificate was found. Sign in to Xcode with your Apple Account, or enter your team ID.")
        }
    }
}
