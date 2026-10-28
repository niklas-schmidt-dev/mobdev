import Foundation
import MobdevCore
import Observation

/// App Store Connect as the window and the settings show it: whether a key is stored, and the
/// team's apps for the sidebar. Each app page loads its own builds, groups, versions and reviews.
@MainActor
@Observable
final class AppStoreModel {
    /// The client the tools use too, so both share one token.
    let connect: AppStoreConnect
    /// Nil while no key is stored.
    private(set) var keyID: String?
    private(set) var issuerID: String?
    private(set) var apps: [AppStoreApp] = []
    private(set) var loadingApps = false
    private(set) var appsError: String?
    @ObservationIgnored private var loadedApps = false

    init(connect: AppStoreConnect) {
        self.connect = connect
        readKey()
    }

    var hasKey: Bool { keyID != nil }

    func app(_ id: String) -> AppStoreApp? { apps.first { $0.id == id } }

    private func readKey() {
        let credentials = connect.keys.load()
        keyID = credentials?.keyID
        issuerID = credentials?.issuerID
    }

    /// Checks and stores a key, then lists its apps.
    func saveKey(issuerID: String, keyID: String, privateKey: String) throws {
        try connect.keys.save(AppStoreCredentials(issuerID: issuerID, keyID: keyID, privateKey: privateKey))
        readKey()
        loadedApps = false
        Task { await refreshApps() }
    }

    func removeKey() throws {
        try connect.keys.remove()
        readKey()
        apps = []
        appsError = nil
        loadedApps = false
    }

    /// "Connected. The key sees 3 apps." or what went wrong.
    func testConnection() async -> (ok: Bool, message: String) {
        do {
            let count = try await connect.appCount()
            return (true, "Connected. The key sees \(count) app\(count == 1 ? "" : "s").")
        } catch {
            return (false, String(describing: error))
        }
    }

    /// The apps, once per launch unless refreshed.
    func loadAppsOnce() async {
        guard !loadedApps else { return }
        await refreshApps()
    }

    func refreshApps() async {
        guard hasKey, !loadingApps else { return }
        loadingApps = true
        defer { loadingApps = false }
        do {
            apps = try await connect.apps()
            appsError = nil
            loadedApps = true
        } catch {
            appsError = String(describing: error)
        }
    }
}

/// A list a page loads from App Store Connect.
enum AppStoreLoad<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}
