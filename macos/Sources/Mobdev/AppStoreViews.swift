import MobdevCore
import SwiftUI

/// The parts of an app's App Store Connect page.
enum AppStoreSection: String, CaseIterable, Identifiable {
    case builds, testFlight, versions, reviews

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builds: "Builds"
        case .testFlight: "TestFlight"
        case .versions: "Versions"
        case .reviews: "Reviews"
        }
    }
}

/// The sidebar's App Store Connect section: the key's apps, or a way to add a key.
struct AppStoreSidebarSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let appStore = model.appStore
        Section("App Store Connect") {
            if !appStore.hasKey {
                SettingsLink {
                    Label("Add API Key…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else if appStore.apps.isEmpty {
                Group {
                    if appStore.loadingApps {
                        Label("Loading Apps…", systemImage: "hourglass")
                    } else if let error = appStore.appsError {
                        Label("Could Not Load Apps", systemImage: "exclamationmark.triangle")
                            .help(error)
                            .contextMenu { Button("Try Again") { Task { await appStore.refreshApps() } } }
                    } else {
                        Label("No Apps", systemImage: "app.dashed")
                    }
                }
                .foregroundStyle(.secondary)
                .selectionDisabled()
            }
            ForEach(appStore.apps) { app in
                NavigationLink(value: Pane.appStoreApp(app.id)) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).lineLimit(1)
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "app.badge")
                    }
                }
                .contextMenu {
                    Button("Refresh Apps") { Task { await appStore.refreshApps() } }
                    Button("Copy Bundle ID") { copy(app.bundleID) }
                    Button("Copy App ID") { copy(app.id) }
                }
            }
        }
        .task(id: appStore.keyID) { await appStore.loadAppsOnce() }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One app in App Store Connect: its builds, TestFlight groups, App Store versions and reviews.
struct AppStoreAppView: View {
    @Environment(AppModel.self) private var model
    let appID: String
    @AppStorage("appStoreSection") private var section = AppStoreSection.builds
    /// Counts up with Refresh, which every part reloads on.
    @State private var revision = 0

    var body: some View {
        let app = model.appStore.app(appID)
        Group {
            if !model.appStore.hasKey {
                ContentUnavailableView {
                    Label("No App Store Connect Key", systemImage: "key")
                } description: {
                    Text("Add an API key in Settings to see this app's builds, TestFlight, versions and reviews.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
            } else if let app {
                switch section {
                case .builds: AppStoreBuildsView(app: app, revision: revision)
                case .testFlight: AppStoreTestFlightView(app: app, revision: revision)
                case .versions: AppStoreVersionsView(app: app, revision: revision)
                case .reviews: AppStoreReviewsView(app: app, revision: revision)
                }
            } else if model.appStore.loadingApps {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "App Not Found", systemImage: "app.dashed",
                    description: Text("The App Store Connect key does not see this app any more."))
            }
        }
        .navigationTitle(app?.name ?? "App Store Connect")
        .navigationSubtitle(app?.bundleID ?? "")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $section) {
                    ForEach(AppStoreSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(app == nil)
            }
            ToolbarItem {
                Button {
                    revision += 1
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .help("Load again from App Store Connect")
                .disabled(app == nil)
            }
        }
    }
}

// MARK: - Loading

/// What a part shows while it loads, when loading failed, when there is nothing, and otherwise its list.
private struct AppStoreLoadView<Value, Content: View>: View {
    let state: AppStoreLoad<[Value]>
    let empty: (title: String, symbol: String, text: String)
    let retry: () -> Void
    @ViewBuilder let content: ([Value]) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: retry)
            }
        case .loaded(let values) where values.isEmpty:
            ContentUnavailableView(empty.title, systemImage: empty.symbol, description: Text(empty.text))
        case .loaded(let values):
            content(values)
        }
    }
}

/// Loads a list into `state`, keeping what is shown while it reloads.
@MainActor
private func load<Value>(_ state: Binding<AppStoreLoad<Value>>, _ fetch: () async throws -> Value) async {
    do {
        state.wrappedValue = .loaded(try await fetch())
    } catch is CancellationError {
    } catch {
        state.wrappedValue = .failed(String(describing: error))
    }
}

/// A state such as READY_FOR_SALE in words, colored by what it means.
private struct StateLabel: View {
    let state: String?

    var body: some View {
        if let state, !state.isEmpty {
            Text(AppStoreFormat.label(state)).foregroundStyle(color(state))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func color(_ state: String) -> Color {
        if ["REJECTED", "INVALID", "FAILED", "BETA_REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "PROCESSING_EXCEPTION"].contains(state) {
            return .red
        }
        if state.contains("WAITING") || state.contains("REVIEW") || state.contains("PROCESSING") || state.hasPrefix("MISSING") {
            return .orange
        }
        if ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "IN_BETA_TESTING", "BETA_APPROVED", "APPROVED", "VALID"].contains(state) {
            return .green
        }
        return .primary
    }
}

private func formatted(_ date: Date?) -> String {
    date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
}

// MARK: - Builds

private struct AppStoreBuildsView: View {
    @Environment(AppModel.self) private var model
    let app: AppStoreApp
    let revision: Int
    @State private var builds: AppStoreLoad<[AppStoreBuild]> = .loading
    @State private var groups: [AppStoreBetaGroup] = []
    @State private var selection: AppStoreBuild.ID?
    /// Counts up after a change, so the list shows it.
    @State private var changes = 0

    var body: some View {
        AppStoreLoadView(
            state: builds, empty: ("No Builds", "shippingbox", "Builds you upload with Xcode or Transporter appear here."),
            retry: { changes += 1 }
        ) { builds in
            Table(builds, selection: $selection) {
                TableColumn("Build") { Text($0.title).monospacedDigit() }
                TableColumn("Platform") { Text($0.platform.map(AppStoreFormat.platform) ?? "—") }
                    .width(ideal: 70)
                TableColumn("Status") { build in StateLabel(state: build.expired ? "EXPIRED" : build.processingState) }
                TableColumn("Internal") { StateLabel(state: $0.internalState) }
                TableColumn("External") { StateLabel(state: $0.externalState) }
                TableColumn("Uploaded") { Text(formatted($0.uploaded)) }
            }
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let build = builds.value?.first(where: { $0.id == selection }) {
                AppStoreBuildInspector(app: app, build: build, groups: groups) { changes += 1 }
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                    .id(build.id)
            }
        }
        .task(id: "\(app.id) \(revision) \(changes)") {
            let connect = model.appStore.connect
            await load($builds) { try await connect.builds(app: app.id, limit: 100) }
            groups = (try? await connect.betaGroups(app: app.id)) ?? groups
        }
    }
}

/// A build's details, its TestFlight groups and What to Test, with the changes behind a confirmation.
private struct AppStoreBuildInspector: View {
    @Environment(AppModel.self) private var model
    let app: AppStoreApp
    let build: AppStoreBuild
    let groups: [AppStoreBetaGroup]
    let changed: () -> Void
    @State private var locale = ""
    @State private var text = ""
    @State private var adding: AppStoreBetaGroup?
    @State private var confirmText = false
    @State private var working = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        let member = groups.filter { group in group.builds.contains { $0.id == build.id } }
        let others = groups.filter { group in !group.builds.contains { $0.id == build.id } }
        Form {
            Section("Build") {
                LabeledContent("Version", value: build.title)
                LabeledContent("Platform", value: build.platform.map(AppStoreFormat.platform) ?? "—")
                LabeledContent("Processing") { StateLabel(state: build.processingState) }
                LabeledContent("Uploaded", value: formatted(build.uploaded))
                LabeledContent(build.expired ? "Expired" : "Expires", value: formatted(build.expires))
                if let minimum = build.minimumOSVersion { LabeledContent("Minimum OS", value: minimum) }
            }
            Section("TestFlight") {
                LabeledContent("Internal testers") { StateLabel(state: build.internalState) }
                LabeledContent("External testers") { StateLabel(state: build.externalState) }
                LabeledContent("Beta app review") { StateLabel(state: build.betaReviewState) }
                LabeledContent("Groups", value: member.isEmpty ? "None" : member.map(\.name).joined(separator: ", "))
                Menu("Add to Group") {
                    ForEach(others) { group in
                        Button("\(group.name) (\(group.isInternal ? "internal" : "external"))") { adding = group }
                    }
                }
                .disabled(others.isEmpty || build.expired || working)
            }
            Section("What to Test") {
                if locales.count > 1 {
                    Picker("Language", selection: $locale) {
                        ForEach(locales, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    LabeledContent("Language", value: locale)
                }
                TextEditor(text: $text)
                    .frame(minHeight: 100)
                    .font(.body)
                HStack {
                    Text("\(text.count) of 4000").font(.caption).foregroundStyle(text.count > 4000 ? .red : .secondary)
                    Spacer()
                    Button("Save…") { confirmText = true }
                        .disabled(working || text == (build.whatToTest[locale] ?? "") || text.count > 4000 || text.isEmpty)
                }
            }
            if let result {
                Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.ok ? .green : .red)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            locale = build.whatToTest.keys.contains(app.primaryLocale)
                ? app.primaryLocale : (locales.first ?? (app.primaryLocale.isEmpty ? "en-US" : app.primaryLocale))
            text = build.whatToTest[locale] ?? ""
        }
        .onChange(of: locale) { text = build.whatToTest[locale] ?? "" }
        .confirmationDialog(
            "Add build \(build.title) to \(adding?.name ?? "the group")?",
            isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } }), presenting: adding
        ) { group in
            Button("Add Build") { add(group) }
        } message: { group in
            Text(
                group.isInternal
                    ? "The testers in \(group.name) can install it in TestFlight right away."
                    : "The testers in \(group.name) can install it once it passed beta app review.")
        }
        .confirmationDialog("Change What to Test of build \(build.title)?", isPresented: $confirmText) {
            Button("Save What to Test") { saveText() }
        } message: {
            Text("TestFlight shows testers the new text (\(locale)).")
        }
    }

    /// The languages it has What to Test in, else the app's primary one.
    private var locales: [String] {
        let existing = build.whatToTest.keys.sorted()
        return existing.isEmpty ? [app.primaryLocale.isEmpty ? "en-US" : app.primaryLocale] : existing
    }

    private func add(_ group: AppStoreBetaGroup) {
        perform("Added build \(build.title) to \(group.name).") {
            try await $0.addBuild(build.id, toGroup: group.id)
        }
    }

    private func saveText() {
        let (locale, text) = (locale, text)
        perform("Saved What to Test.") {
            try await $0.setWhatToTest(build: build.id, locale: locale, text: text)
        }
    }

    private func perform(_ success: String, _ change: @escaping @Sendable (AppStoreConnect) async throws -> Void) {
        let connect = model.appStore.connect
        working = true
        result = nil
        Task {
            do {
                try await change(connect)
                result = (true, success)
                changed()
            } catch {
                result = (false, String(describing: error))
            }
            working = false
        }
    }
}

// MARK: - TestFlight

private struct AppStoreTestFlightView: View {
    @Environment(AppModel.self) private var model
    let app: AppStoreApp
    let revision: Int
    @State private var groups: AppStoreLoad<[AppStoreBetaGroup]> = .loading
    @State private var retries = 0

    var body: some View {
        AppStoreLoadView(
            state: groups, empty: ("No TestFlight Groups", "person.2", "Create groups of testers in App Store Connect › TestFlight."),
            retry: { retries += 1 }
        ) { groups in
            Form {
                ForEach(groups) { group in
                    Section {
                        LabeledContent("Testers", value: group.testerCount.map(String.init) ?? "—")
                        if let link = group.publicLink, let url = URL(string: link) {
                            LabeledContent("Public link") { Link(link, destination: url).lineLimit(1).truncationMode(.middle) }
                        }
                        let current = group.builds.filter { !$0.expired }
                        if current.isEmpty {
                            Text("No current builds").foregroundStyle(.secondary)
                        }
                        ForEach(current.prefix(8)) { build in
                            LabeledContent("Build \(build.number)", value: formatted(build.uploaded))
                        }
                    } header: {
                        HStack {
                            Text(group.name)
                            Spacer()
                            Text(group.isInternal ? "Internal" : "External").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .task(id: "\(app.id) \(revision) \(retries)") {
            let connect = model.appStore.connect
            await load($groups) { try await connect.betaGroups(app: app.id) }
        }
    }
}

// MARK: - Versions

private struct AppStoreVersionsView: View {
    @Environment(AppModel.self) private var model
    let app: AppStoreApp
    let revision: Int
    @State private var versions: AppStoreLoad<[AppStoreVersion]> = .loading
    @State private var retries = 0

    var body: some View {
        AppStoreLoadView(
            state: versions, empty: ("No App Store Versions", "storefront", "Versions you prepare in App Store Connect appear here."),
            retry: { retries += 1 }
        ) { versions in
            Table(versions) {
                TableColumn("Version") { Text($0.version).monospacedDigit() }
                TableColumn("Platform") { Text(AppStoreFormat.platform($0.platform)) }
                    .width(ideal: 70)
                TableColumn("State") { StateLabel(state: $0.state) }
                TableColumn("Build") { Text($0.build ?? "—").monospacedDigit() }
                TableColumn("Release") { Text(release($0)) }
                TableColumn("Created") { Text(formatted($0.created)) }
            }
        }
        .task(id: "\(app.id) \(revision) \(retries)") {
            let connect = model.appStore.connect
            await load($versions) { try await connect.versions(app: app.id, limit: 50) }
        }
    }

    private func release(_ version: AppStoreVersion) -> String {
        var text =
            switch version.releaseType {
            case "MANUAL": "Manually"
            case "AFTER_APPROVAL": "After approval"
            case "SCHEDULED": "Scheduled \(version.earliestRelease.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")"
            default: "—"
            }
        if let phased = version.phasedRelease, phased.state != "INACTIVE" {
            text += ", phased: \(AppStoreFormat.label(phased.state).lowercased())\(phased.day.map { ", day \($0) of 7" } ?? "")"
        }
        return text
    }
}

// MARK: - Reviews

private struct AppStoreReviewsView: View {
    @Environment(AppModel.self) private var model
    let app: AppStoreApp
    let revision: Int
    @State private var reviews: AppStoreLoad<[AppStoreReview]> = .loading
    @State private var selection: AppStoreReview.ID?
    @AppStorage("appStoreReviewsUnanswered") private var unanswered = false
    @State private var changes = 0

    var body: some View {
        AppStoreLoadView(
            state: reviews,
            empty: (unanswered ? "No Reviews Without a Reply" : "No Reviews", "star.bubble", "Customer reviews from the App Store appear here."),
            retry: { changes += 1 }
        ) { reviews in
            List(reviews, selection: $selection) { review in
                AppStoreReviewRow(review: review)
            }
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let review = reviews.value?.first(where: { $0.id == selection }) {
                AppStoreReviewInspector(review: review) { changes += 1 }
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
                    .id(review.id)
            }
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $unanswered) {
                    Label("Without Reply", systemImage: "line.3.horizontal.decrease")
                }
                .help("Show only reviews without a published reply")
            }
        }
        .task(id: "\(app.id) \(revision) \(changes) \(unanswered)") {
            let connect = model.appStore.connect
            let unanswered = unanswered
            await load($reviews) { try await connect.reviews(app: app.id, unanswered: unanswered, limit: 100) }
        }
    }
}

private struct Stars: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityElement()
        .accessibilityLabel("\(rating) of 5 stars")
    }
}

private struct AppStoreReviewRow: View {
    let review: AppStoreReview

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Stars(rating: review.rating)
                Text(review.title).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Text([review.territory, review.created.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(review.body).lineLimit(3).foregroundStyle(.secondary)
            if let response = review.response {
                Label(response.state == "PUBLISHED" ? "Replied" : "Reply waiting for Apple", systemImage: "arrowshape.turn.up.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A review in full, with a reply that replaces the earlier one after a confirmation.
private struct AppStoreReviewInspector: View {
    @Environment(AppModel.self) private var model
    let review: AppStoreReview
    let changed: () -> Void
    @State private var reply = ""
    @State private var confirm = false
    @State private var working = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        Form {
            Section {
                Stars(rating: review.rating)
                Text(review.title).font(.headline)
                Text(review.body).textSelection(.enabled)
                LabeledContent("By", value: review.reviewer.isEmpty ? "—" : review.reviewer)
                LabeledContent("Country", value: review.territory)
                LabeledContent("Date", value: formatted(review.created))
            }
            if let response = review.response {
                Section("Your reply") {
                    Text(response.body).textSelection(.enabled)
                    LabeledContent("State", value: response.state == "PUBLISHED" ? "Published" : "Waiting for Apple")
                    LabeledContent("Changed", value: formatted(response.modified))
                }
            }
            Section(review.response == nil ? "Reply" : "New reply") {
                TextEditor(text: $reply)
                    .frame(minHeight: 120)
                    .font(.body)
                HStack {
                    Text("\(reply.count) of 5970").font(.caption).foregroundStyle(reply.count > 5970 ? .red : .secondary)
                    Spacer()
                    Button("Send Reply…") { confirm = true }
                        .disabled(working || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reply.count > 5970)
                }
            }
            if let result {
                Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.ok ? .green : .red)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(review.response == nil ? "Send this reply?" : "Replace your reply?", isPresented: $confirm) {
            Button(review.response == nil ? "Send Reply" : "Replace Reply") { send() }
        } message: {
            Text("Apple checks a reply before it appears with the review on the App Store, where everyone can read it.")
        }
    }

    private func send() {
        let (connect, text, id) = (model.appStore.connect, reply, review.id)
        working = true
        result = nil
        Task {
            do {
                try await connect.reply(toReview: id, text: text)
                result = (true, "Sent. Apple checks it before it appears.")
                reply = ""
                changed()
            } catch {
                result = (false, String(describing: error))
            }
            working = false
        }
    }
}
