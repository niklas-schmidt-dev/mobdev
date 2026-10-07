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
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Get Started").font(.title3.weight(.semibold))
                            Text("Your agent does the work through Mobdev; these steps get it there.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Hide") { hidden = (hidden.split(separator: "\n").map(String.init) + [folder.path]).joined(separator: "\n") }
                            .buttonStyle(.link)
                            .help("Hide these steps for this project; the prompts below stay")
                    }
                    step(1, "Connect your agent", done: done[0]) { connect }
                    step(2, "Let it write the first tests", done: done[1]) {
                        PromptBlock(prompt: ProjectPrompts.firstTests(context))
                    }
                    step(3, "Run them", done: done[2]) {
                        HStack(spacing: 10) {
                            Text("Here, on a device, or ask your agent to call run_tests. Results stay in Runs.")
                                .foregroundStyle(.secondary)
                            if let runTests {
                                Button("Run Tests", systemImage: "play.fill", action: runTests).disabled(!hasTests)
                            }
                        }
                    }
                    step(4, "Run them in CI", done: done[3]) {
                        PromptBlock(prompt: ProjectPrompts.continuousIntegration(context))
                    }
                }
                .padding(18)
                .background(.background.secondary, in: .rect(cornerRadius: 14))
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
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.18)).frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold)).monospacedDigit()
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

/// Prompts for the project's agent, below its overview's cards.
struct ProjectAgentPrompts: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    let project: TestProject?
    @State private var expanded: String?

    var body: some View {
        let context = ProjectPrompts.Context(
            project: folder, bundleID: project?.app.bundleID, device: model.devices.first(where: \.isReady)?.name)
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask Your Agent").font(.title3.weight(.semibold))
            Text("Copy a prompt into Claude Code, Codex or another agent that has Mobdev. Each names the skill that does the job.")
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(ProjectPrompts.all(context)) { prompt in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: prompt.systemImage).foregroundStyle(.tint).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(prompt.title).font(.headline)
                                Text(prompt.summary).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let skill = prompt.skill {
                                Text(skill).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary.opacity(0.6), in: .capsule)
                            }
                            Button(expanded == prompt.id ? "Hide" : "Show") {
                                withAnimation(.snappy) { expanded = expanded == prompt.id ? nil : prompt.id }
                            }
                            .buttonStyle(.link)
                            CopyButton(title: "Copy Prompt") { prompt.text }
                        }
                        if expanded == prompt.id {
                            Text(prompt.text).font(.callout).textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                        }
                    }
                    .padding(.vertical, 10)
                    if prompt.id != ProjectPrompts.all(context).last?.id { Divider() }
                }
            }
            .padding(.horizontal, 14)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
        }
    }
}

/// A prompt with its skill, the text and a copy button.
private struct PromptBlock: View {
    let prompt: ProjectPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt.text)
                .font(.callout)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            HStack {
                if let skill = prompt.skill {
                    Text("Uses the \(skill) skill.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                CopyButton(title: "Copy Prompt") { prompt.text }
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
