import AppKit
import MobdevCore
import SwiftUI

/// What to do with a new project, at the top of its overview: connect an agent, let it write the
/// first tests, run them, run them in CI. Each step ticks itself off from what the project holds;
/// the card goes once all are done, or when hidden.
struct ProjectGettingStarted: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    let project: TestProject?
    /// Runs the project's tests on the overview's device; nil when no device is ready.
    let runTests: (() -> Void)?
    @AppStorage("gettingStartedHidden") private var hidden = ""
    @State private var hasRuns = false
    @State private var runsInCI = false
    @State private var agent = Agent.claudeCode

    enum Agent: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code", codex = "Codex", others = "Cursor and Others"
        var id: String { rawValue }
    }

    private var hasTests: Bool { !(project?.tests.isEmpty ?? true) }
    private var isHidden: Bool { hidden.split(separator: "\n").contains { $0 == folder.path } }
    private var done: [Bool] { [model.agentConnected, hasTests, hasRuns, runsInCI] }
    private var context: ProjectPrompts.Context {
        ProjectPrompts.Context(
            project: folder, bundleID: project?.app.bundleID, device: model.devices.first(where: \.isReady)?.name)
    }

    var body: some View {
        Group {
            if !isHidden && done.contains(false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Get Started").font(.title2.weight(.semibold))
                            Text("Your agent does the work through Mobdev. These steps get it there.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Hide") { hidden = (hidden.split(separator: "\n").map(String.init) + [folder.path]).joined(separator: "\n") }
                            .buttonStyle(.link)
                            .help("Hide these steps for this project; the prompts below stay")
                    }
                    step(1, "Connect your agent", done: done[0]) { connect }
                    step(2, "Let it write the first tests", done: done[1]) {
                        PromptLine(prompt: ProjectPrompts.firstTests(context))
                    }
                    step(3, "Run them", done: done[2]) {
                        HStack(spacing: 10) {
                            Text("Here on a device, or your agent calls run_tests. Results stay in Runs.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let runTests {
                                Button("Run Tests", systemImage: "play.fill", action: runTests)
                                    .buttonStyle(.glass)
                                    .disabled(!hasTests)
                            }
                        }
                    }
                    step(4, "Run them in CI", done: done[3]) {
                        PromptLine(prompt: ProjectPrompts.continuousIntegration(context))
                    }
                }
                .padding(22)
                .background(.background.secondary, in: .rect(cornerRadius: 16))
            }
        }
        .task(id: "\(folder.path) \(model.projectRevision(folder)) \(model.testResults[folder.path]?.started.timeIntervalSince1970 ?? 0)") {
            guard let project else { return }
            let repository = ProjectIcons.repository(of: folder)
            let found = await Task.detached(priority: .utility) {
                (!TestRuns.runs(for: project).isEmpty, ProjectPrompts.runsInCI(repository))
            }.value
            hasRuns = found.0
            runsInCI = found.1
        }
    }

    private func step(_ number: Int, _ title: String, done: Bool, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.tint)
                }
            }
            .accessibilityLabel(done ? "Done" : "Step \(number)")
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(done ? .secondary : .primary)
                if !done { content() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var connect: some View {
        Picker("Agent", selection: $agent) {
            ForEach(Agent.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        switch agent {
        case .claudeCode where !MobdevPaths.isDevelopmentBuild:
            CodeBlock(
                caption: "In Claude Code, add Mobdev's plugin: its MCP server and skills in one go.",
                code: "/plugin marketplace add niklas-schmidt-dev/mobdev\n/plugin install mobdev@mobdev")
        case .claudeCode:
            CodeBlock(caption: "Run once in Terminal.", code: model.claudeCodeCommand)
            CodeBlock(caption: "Then add the skills.", code: Self.skillsCommand)
        case .codex:
            CodeBlock(caption: "Add to ~/.codex/config.toml.", code: model.codexConfig)
            CodeBlock(caption: "Then add the skills.", code: Self.skillsCommand)
        case .others:
            CodeBlock(caption: "Add to the app's mcpServers config.", code: model.jsonConfig)
            CodeBlock(caption: "Then add the skills.", code: Self.skillsCommand)
        }
        Text(
            "Start the agent in the app's repository, \(ProjectIcons.repository(of: folder).path): its calls then use this project. This step ticks itself off when the agent first calls Mobdev."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    static let skillsCommand = "npx skills add niklas-schmidt-dev/mobdev"
}

/// Prompts for the project's agent, below its overview's run actions.
struct ProjectAgentPrompts: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    let project: TestProject?

    var body: some View {
        let context = ProjectPrompts.Context(
            project: folder, bundleID: project?.app.bundleID, device: model.devices.first(where: \.isReady)?.name)
        let prompts = ProjectPrompts.all(context)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ask Your Agent").font(.title2.weight(.semibold))
                Text("Prompts for Claude Code, Codex or any agent with Mobdev, filled in for this project.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(prompts) { prompt in
                    PromptRow(prompt: prompt)
                    if prompt.id != prompts.last?.id { Divider().padding(.leading, 44) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
        }
    }
}

/// One prompt: what it does and its skill, the text when opened, and a copy button.
private struct PromptRow: View {
    let prompt: ProjectPrompt
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: prompt.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                    Text([prompt.summary, prompt.skill].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                Button {
                    withAnimation(.snappy) { open.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .buttonStyle(.borderless)
                .help(open ? "Hide the prompt" : "Show the prompt")
                .accessibilityLabel(open ? "Hide Prompt" : "Show Prompt")
                CopyButton { prompt.text }
                    .controlSize(.small)
            }
            if open {
                Text(prompt.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                    .padding(.leading, 40)
            }
        }
        .padding(.vertical, 10)
    }
}

/// A Get Started step's prompt: its line with the skill, the text on demand, and a copy button.
private struct PromptLine: View {
    let prompt: ProjectPrompt
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text([prompt.summary, prompt.skill.map { "Uses \($0)." }].compactMap { $0 }.joined(separator: " "))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(open ? "Hide Prompt" : "Show Prompt") { withAnimation(.snappy) { open.toggle() } }
                    .buttonStyle(.borderless)
                CopyButton(title: "Copy Prompt") { prompt.text }
            }
            if open {
                Text(prompt.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            }
        }
    }
}

/// Commands or config to copy, with a line on where they go.
private struct CodeBlock: View {
    let caption: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(caption).font(.callout).foregroundStyle(.secondary)
                Spacer()
                CopyButton { code }
            }
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }
}
