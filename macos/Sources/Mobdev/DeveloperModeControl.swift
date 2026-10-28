import MobdevCore
import SwiftUI

/// Developer Mode control for one iPhone, in its info: Mobdev builds Mobdev Runner with Xcode, signs
/// it with the chosen team and keeps it running on the phone. It then taps, swipes, types and
/// presses buttons, and serves the UI tree for ui_tree and tap_element. It starts by itself once
/// Developer Mode is on; Turn Off leaves the iPhone to Bluetooth.
struct DeveloperModeControl: View {
    @Environment(AppModel.self) private var model
    let state: DeviceState

    private var udid: String? { state.info?.id }
    /// Building, starting, running or failed: Turn Off applies.
    private var isActive: Bool { (state.runner ?? .off) != .off }

    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    if state.runnerStarting { ProgressView().controlSize(.small) }
                    Text(status.title).foregroundStyle(.secondary)
                }
            }
            if let detail = status.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            team
            HStack {
                if isActive {
                    if case .failed = state.runner { Button("Try Again") { model.restartRunner(state.id) } }
                    Button("Turn Off") { model.setRunner(false, for: state.id) }
                } else {
                    Button("Turn On") { model.setRunner(true, for: state.id) }
                        .buttonStyle(.glassProminent)
                        .disabled(udid == nil || !UIRunner.isTeamID(model.settings.runnerTeam))
                        .help("Build Mobdev Runner and start it on the \(state.noun) now")
                }
            }
        } header: {
            Text("Developer Mode Control")
        } footer: {
            Text(
                "With Developer Mode on, \(MobdevPaths.appName) builds Mobdev Runner, a small UI test, with Xcode, signs it with your team and keeps it running on the \(state.noun). It then taps, swipes, types and presses buttons, and agents can find elements by identifier or label (ui_tree, tap_element). No Bluetooth or AssistiveTouch needed. The first build takes a minute or two. Turned off, \(MobdevPaths.appName) uses Bluetooth."
            )
        }
        .task { await model.refreshTeams() }
    }

    private var status: (title: String, detail: String?) {
        let control = state.control(teamChosen: UIRunner.isTeamID(model.settings.runnerTeam))
        return (control.title, control.detail)
    }

    /// A menu of the teams found, or a field for the team ID when none is.
    @ViewBuilder private var team: some View {
        let selection = Binding(get: { model.settings.runnerTeam }, set: { model.setRunnerTeam($0) })
        if let teams = model.teams, !teams.isEmpty {
            Picker("Team", selection: selection) {
                ForEach(teams) { Text("\($0.name) (\($0.id))").tag($0.id) }
                if !teams.contains(where: { $0.id == model.settings.runnerTeam }) {
                    Text(model.settings.runnerTeam.isEmpty ? "None" : model.settings.runnerTeam).tag(model.settings.runnerTeam)
                }
            }
        } else if model.teams != nil {
            TextField("Team ID", text: selection, prompt: Text("ABCDE12345"))
                .help("No Apple Development certificate was found. Sign in to Xcode with your Apple Account, or enter your team ID.")
        }
    }
}

extension DeviceState {
    /// What Mobdev Runner does on this iPhone, and what to do about it, for the info, the panel and
    /// Diagnose: a step state, a short title and the detail.
    func control(teamChosen: Bool) -> (step: StepRow.State, title: String, detail: String?) {
        switch runner ?? .off {
        case .running: return (.done, "Controls the \(noun)", nil)
        case .failed(let reason): return (.attention, "Could not start", reason)
        case .building, .starting:
            return (.waiting, runner?.summary ?? "Starting…", "The first build takes a minute or two.")
        case .off: break
        }
        if runnerChoice == .off { return (.info, "Off", "Turned off for this \(noun): input goes over Bluetooth.") }
        guard onUSB else { return (.waiting, "Starts when the \(noun) is connected", nil) }
        if runnerChoice == .on { return (.waiting, "Starting…", nil) }
        switch developerMode {
        case false?:
            return (
                .attention, "Waiting for Developer Mode",
                "On the \(noun): Settings › Privacy & Security › Developer Mode. The \(noun) restarts, then \(MobdevPaths.appName) starts by itself."
            )
        case nil:
            return (
                .info, "Waiting for Developer Mode",
                "Xcode does not report Developer Mode for this \(noun) yet. With Xcode installed, open Window › Devices and Simulators once while the \(noun) is connected, or click Turn On in its info."
            )
        case true? where teamChosen:
            return (.waiting, "Starting…", nil)
        case true?:
            return (
                .attention, "Needs a development team",
                "Sign in to Xcode with your Apple Account (Xcode › Settings › Apple Accounts), or enter your team ID in the \(noun)'s info."
            )
        }
    }
}
