import Foundation

// MARK: - run_flow

extension PhoneTools {
    static let flowDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "run_flow", title: "Run flow",
            description:
                "Replay a flow: a list of tool calls saved as JSON, e.g. recorded in the Mobdev app or written by hand ({\"steps\": [{\"tap_element\": {\"id\": \"login\"}}, {\"type_text\": {\"text\": \"hi\"}}, \"home\"]}), or a Maestro flow (.yaml). Control steps decide what runs: {\"if\": {\"visible\": {\"text\": \"Allow\"}, \"then\": [...], \"else\": [...]}}, {\"repeat\": {\"times\": 3, \"steps\": [...]}} or with while_visible/until_visible and max, {\"retry\": {\"times\": 2, \"steps\": [...]}}, {\"run\": \"other.json\"}, {\"set\": {\"NAME\": \"value\"}} and {\"extract\": {\"id\": \"total\", \"into\": \"TOTAL\"}} for ${NAME} in later steps; \"optional\": true next to a step lets it fail. Stops at the first step that fails and says which, nested ones numbered like 3.2. Pass path (a .json or .yaml file on this Mac) or steps, and video to keep a recording of the run.",
            inputSchema: schema([
                "path": ["type": "string", "description": "A flow file on the Mac that runs Mobdev: .json, or Maestro's .yaml"],
                "steps": [
                    "type": "array", "description": "The steps inline, each a tool name or {\"tool\": {arguments}}",
                ],
                "variables": [
                    "type": "object", "additionalProperties": ["type": "string"],
                    "description": "Values for ${NAME} in the steps",
                ],
                "video": [
                    "type": "string",
                    "description":
                        "Where to save a video of the run on the Mac that runs Mobdev: an absolute path ending in .mp4, in an existing folder. A file there is replaced.",
                ],
            ]),
            readOnly: false)
    ]

    /// Tools a flow may not call: another flow or the tests, and nothing that picks a different device.
    static let flowExcluded: Set<String> = ["run_flow", "run_tests", "list_devices", "crawl_app"]

    func runFlowTool(_ args: Arguments, source: String) async throws -> ToolOutput {
        var flow: Flow
        // Named baselines of a flow file live next to it.
        var checks = CheckContext.current
        if args.has("path") {
            let path = (try args.string("path") as NSString).expandingTildeInPath
            let file = URL(fileURLWithPath: path)
            flow = try Flow.load(file)
            checks = CheckContext(root: file.deletingLastPathComponent(), artifacts: nil)
        } else if let steps = args.value["steps"], !steps.isNull {
            flow = try Flow.parse(steps)
            try flow.loadSubflows(relativeTo: nil)
        } else {
            throw ToolFailure("Pass path or steps.")
        }
        let variables = Variables(values: try args.stringDictionary("variables"))
        let video = try args.has("video") ? Flow.videoURL(try args.string("video")) : nil
        let result = await CheckContext.$current.withValue(checks) {
            await Flow.recording(phone, to: video) {
                await run(flow, variables: variables, source: source)
            }
        }
        return ToolOutput(text: result.text, data: result.json, isError: !result.passed)
    }

    /// Runs every step through `call`, so each shows in the device's activity and records like any
    /// other call, and control steps decide what runs. Stops at the first failure, and before the
    /// next step once the task is cancelled. `progress` hears of each step when it is done, the
    /// steps inside a control step before the control step itself.
    public func run(
        _ flow: Flow, variables: [String: String] = [:], source: String,
        progress: (@Sendable (FlowResult.StepResult) -> Void)? = nil
    ) async -> FlowResult {
        await run(flow, variables: Variables(values: variables), source: source, progress: progress)
    }

    func run(
        _ flow: Flow, variables: Variables, source: String,
        progress: (@Sendable (FlowResult.StepResult) -> Void)? = nil
    ) async -> FlowResult {
        let started = Date()
        var run = FlowRun(variables: variables, source: source, progress: progress)
        if let (index, error) = Flow.unsetVariable(in: flow.steps, variables: variables) {
            // Nothing runs: a typo in the last step must not leave a half-run flow.
            let result = FlowResult.StepResult(
                step: flow.steps[index], text: error.description, passed: false, seconds: 0, number: String(index + 1))
            run.results.append(result)
            progress?(result)
        } else {
            _ = await runSteps(flow.steps, number: { String($0 + 1) }, round: nil, run: &run)
        }
        return FlowResult(flow: flow, steps: run.results, seconds: Date().timeIntervalSince(started))
    }
}

// MARK: - Steps

/// One run of a flow: what ran so far, the variables, and how many steps it took.
struct FlowRun {
    var variables: Variables
    let source: String
    let progress: (@Sendable (FlowResult.StepResult) -> Void)?
    var results: [FlowResult.StepResult] = []
    var executed = 0

    init(variables: Variables, source: String, progress: (@Sendable (FlowResult.StepResult) -> Void)?) {
        self.variables = variables
        self.source = source
        self.progress = progress
    }

    /// The failures from `start` on did not stop the flow: an optional step, or a retry that runs
    /// the steps again.
    mutating func tolerate(from start: Int) {
        for index in results.indices.dropFirst(start) where !results[index].passed { results[index].tolerated = true }
    }

    /// The number of the innermost failure from `start` on, for the control step that held it.
    func failedNumber(from start: Int) -> String {
        results.dropFirst(start).last(where: { !$0.passed && !$0.tolerated })?.number ?? "?"
    }
}

extension PhoneTools {
    /// Runs steps in order and stops at the first that fails. False when one failed.
    private func runSteps(_ steps: [Flow.Step], number: (Int) -> String, round: String?, run: inout FlowRun) async -> Bool
    {
        for (index, step) in steps.enumerated() {
            guard await runStep(step, number: number(index), round: round, run: &run) else { return false }
        }
        return true
    }

    /// Runs one step, a tool call or a control step with everything inside it, and reports it.
    /// False when it failed and the flow stops.
    private func runStep(_ step: Flow.Step, number: String, round: String?, run: inout FlowRun) async -> Bool {
        let started = Date()
        let slot = run.results.count
        var result = FlowResult.StepResult(step: step, text: "", passed: false, seconds: 0, number: number, round: round)
        if Task.isCancelled {
            result.text = "Cancelled."
        } else if run.executed >= Flow.maxRunSteps {
            result.text =
                "The flow ran \(Flow.maxRunSteps) steps, the most one run may take. Lower the times of its repeat and retry steps."
        } else {
            run.executed += 1
            run.results.append(result)  // Its place, before the steps inside it.
            let outcome: (text: String, passed: Bool)
            if let control = step.control {
                outcome = await runControl(control, number: number, round: round, run: &run)
            } else {
                let output = await callTool(step, run: run)
                outcome = (output.text, !output.isError)
            }
            result.text = run.variables.redact(outcome.text)
            result.passed = outcome.passed
            result.seconds = Date().timeIntervalSince(started)
            if !result.passed, step.optional, !Task.isCancelled {
                run.tolerate(from: slot)
                result.tolerated = true
                result.text = "Failed, and the flow goes on since the step is optional: " + result.text
            }
            run.results[slot] = result
            run.progress?(result)
            return result.passed || result.tolerated
        }
        run.results.append(result)
        run.progress?(result)
        return false
    }

    private func callTool(_ step: Flow.Step, run: FlowRun) async -> ToolOutput {
        if Self.flowExcluded.contains(step.tool) || step.arguments["device"] != nil {
            return ToolOutput(
                text: "\(step.tool) cannot run inside a flow; a flow runs on one device, without device arguments.",
                isError: true)
        }
        var arguments = step.arguments
        arguments["screenshot"] = false
        var output: ToolOutput
        do {
            let filled = try run.variables.substitute(.object(arguments))
            output = try await call(step.tool, arguments: filled, source: run.source, screenshotByDefault: false)
        } catch {
            output = ToolOutput(text: String(describing: error), isError: true)
        }
        // A wait interrupted by the cancellation says so, not "CancellationError()".
        if output.isError, Task.isCancelled { output = ToolOutput(text: "Cancelled.", isError: true) }
        return output
    }

    /// What a control step does, and what to say about it.
    private func runControl(_ control: Flow.Control, number: String, round: String?, run: inout FlowRun) async -> (
        text: String, passed: Bool
    ) {
        let start = run.results.count
        let inner = { (index: Int) in "\(number).\(index + 1)" }
        do {
            switch control {
            case .set(let values):
                var said: [String] = []
                for name in values.keys.sorted() {
                    let value = try run.variables.substitute(values[name]!)
                    run.variables.set(name, value)
                    said.append("\(name) is \(JSONValue.string(value).compactString)")
                }
                return (said.joined(separator: ", ") + ".", true)
            case .extract(let extraction):
                let (value, element) = try await extract(extraction, variables: run.variables)
                run.variables.set(extraction.into, value)
                return ("\(extraction.into) is \(JSONValue.string(value).compactString), from \(element).", true)
            case .branch(let condition, let then, let otherwise):
                let (holds, what) = try await check(condition, variables: run.variables)
                let steps = holds ? then : otherwise
                let offset = holds ? 0 : then.count
                guard !steps.isEmpty else { return ("\(what); nothing to do.", true) }
                let which = holds ? "then" : "else"
                if await runSteps(steps, number: { "\(number).\(offset + $0 + 1)" }, round: round, run: &run) {
                    return ("\(what), so the \(which) steps ran.", true)
                }
                return ("\(what); step \(run.failedNumber(from: start)) of the \(which) steps failed.", false)
            case .loop(let loop, let steps):
                var rounds = 0
                while true {
                    if Task.isCancelled { return ("Cancelled after \(rounds) rounds.", false) }
                    func ran(until reason: String) -> String {
                        "Ran \(rounds) \(rounds == 1 ? "time" : "times"), until \(reason)."
                    }
                    switch loop {
                    case .times(let times):
                        if rounds == times { return ("Ran \(times) times.", true) }
                    case .whileVisible(let target, let max):
                        let what = describe(try filled(target, run.variables))
                        if !(try await isVisible(target, variables: run.variables)) {
                            return (ran(until: "\(what) was not visible"), true)
                        }
                        // The cap ends the loop like Maestro's times: what follows checks the screen.
                        if rounds == max { return ("Stopped after \(max) rounds, the most it may run; \(what) is still visible.", true) }
                    case .untilVisible(let target, let max):
                        let what = describe(try filled(target, run.variables))
                        if try await isVisible(target, variables: run.variables) {
                            return (ran(until: "\(what) was visible"), true)
                        }
                        if rounds == max {
                            return ("Stopped after \(max) rounds, the most it may run; \(what) is still not visible.", true)
                        }
                    }
                    rounds += 1
                    let label = rounds > 1 ? "round \(rounds)" : round
                    guard await runSteps(steps, number: inner, round: label, run: &run) else {
                        return ("Step \(run.failedNumber(from: start)) failed in round \(rounds).", false)
                    }
                }
            case .retry(let times, let steps):
                for attempt in 1...(times + 1) {
                    let mark = run.results.count
                    let label = attempt > 1 ? "attempt \(attempt)" : round
                    if await runSteps(steps, number: inner, round: label, run: &run) {
                        return (attempt == 1 ? "Passed the first time." : "Passed on attempt \(attempt).", true)
                    }
                    if Task.isCancelled || attempt == times + 1 { break }
                    run.tolerate(from: mark)
                }
                return ("Failed \(times + 1) times; the last time at step \(run.failedNumber(from: start)).", false)
            case .subflow(let path, let flow):
                guard let flow else { return ("\(path) was not loaded; run the flow from its file.", false) }
                if await runSteps(flow.steps, number: inner, round: round, run: &run) {
                    return ("Ran \"\(flow.name)\" (\(flow.steps.count) steps).", true)
                }
                return ("Step \(run.failedNumber(from: start)) of \"\(flow.name)\" failed.", false)
            }
        } catch {
            return (String(describing: error), false)
        }
    }

    // MARK: Conditions

    /// Whether a condition holds now, and how to say so.
    private func check(_ condition: Flow.Condition, variables: Variables) async throws -> (Bool, String) {
        switch condition {
        case .visible(let target):
            let target = try filled(target, variables)
            return try await isVisible(target, variables: variables)
                ? (true, "\(describe(target)) is visible") : (false, "\(describe(target)) is not visible")
        case .notVisible(let target):
            let target = try filled(target, variables)
            return try await isVisible(target, variables: variables)
                ? (false, "\(describe(target)) is visible") : (true, "\(describe(target)) is not visible")
        case .platform(let platform):
            let current = self.platform
            return (current == platform, "The device runs \(current == "ios" ? "iOS" : "Android")")
        }
    }

    /// "ios" for iPhones and simulators, "android" for Android.
    var platform: String {
        if let device = phone as? any Device { return TestCase.platformName(device.kind) }
        return "ios"
    }

    private func filled(_ target: Flow.Target, _ variables: Variables) throws -> Flow.Target {
        Flow.Target(id: try target.id.map(variables.substitute), text: try target.text.map(variables.substitute))
    }

    private func describe(_ target: Flow.Target) -> String {
        target.id.map { "id \"\($0)\"" } ?? "\"\(target.text ?? "")\""
    }

    /// Whether an element or text is on screen now: from the UI tree where there is one, else for
    /// text from text recognition. Does not wait for it; only a tree that cannot be read yet, as
    /// while an app launches, is waited for a few seconds.
    func isVisible(_ target: Flow.Target, variables: Variables) async throws -> Bool {
        let target = try filled(target, variables)
        let query = ElementQuery(id: target.id, text: target.id == nil ? target.text : nil)
        let deadline = Date().addingTimeInterval(5)
        while true {
            do {
                guard let elements = try await phone.uiTree() else { break }
                return query.matches(in: elements).contains { element in
                    (0...1).contains(element.center.x) && (0...1).contains(element.center.y)
                }
            } catch {
                if Date() >= deadline { throw error }
                try await pause(0.5)
            }
        }
        guard target.id == nil, let text = target.text else {
            throw ToolFailure("This device has no UI tree, so a flow cannot look for an id on it. Look for text instead.")
        }
        let (frame, _) = try currentFrame()
        return !(try await screenText(text, in: frame).matches.isEmpty)
    }

    /// The value or label of an element of the UI tree, waiting for it like tap_element, and how to
    /// say which element it was.
    private func extract(_ extraction: Flow.Extraction, variables: Variables) async throws -> (String, String) {
        let target = try filled(extraction.target, variables)
        let query = ElementQuery(id: target.id, text: target.id == nil ? target.text : nil)
        let elements = try await poll(for: extraction.timeout ?? 5) { !query.matches(in: $0).isEmpty } ?? []
        let matches = query.matches(in: elements)
        guard !matches.isEmpty else {
            throw ToolFailure("No element with \(query) to extract from. Call ui_tree to see what is there.")
        }
        if extraction.index == nil, matches.count > 1 {
            let list = matches.enumerated().map { "\($0): \($1.role) \"\($1.label)\"" }
            throw ToolFailure("\(matches.count) elements match. Pass index:\n" + list.joined(separator: "\n"))
        }
        let index = extraction.index ?? 0
        guard index < matches.count else { throw ToolFailure("index \(index) is out of range; \(matches.count) matches.") }
        let element = matches[index]
        let name = "\(element.role)\(element.label.isEmpty ? "" : " \"\(element.label)\"")"
        switch extraction.from {
        case "label": return (element.label, "the label of \(name)")
        case "value": return (element.value, "the value of \(name)")
        default:
            return element.value.isEmpty ? (element.label, "the label of \(name)") : (element.value, "the value of \(name)")
        }
    }
}
