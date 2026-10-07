import CryptoKit
import Foundation

/// scrcpy's server (https://github.com/Genymobile/scrcpy, Apache-2.0), a small Java program Mobdev
/// runs on Android devices with `app_process` to stream the screen and inject input. It is not in
/// git: scripts/build-app.sh downloads this pinned release into the app's Resources, and builds
/// run from `swift build` (tests, the command line) download it into `.build` on first use. Keep
/// the version and checksum in step with scripts/build-app.sh; a test compares them.
enum ScrcpyServer {
    static let version = "3.3.4"
    static let sha256 = "8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e"
    static var fileName: String { "scrcpy-server-v\(version)" }
    static var downloadURL: URL {
        URL(string: "https://github.com/Genymobile/scrcpy/releases/download/v\(version)/\(fileName)")!
    }

    /// The checked file, or nil with the reason. Looked up once per process.
    static func file() async -> Result<URL, DeveloperError> {
        if let known = found.get() { return known }
        let result = await locate()
        found.set(result)
        return result
    }

    private static let found = Locked<Result<URL, DeveloperError>?>(nil)

    /// `macos/.build`, next to the sources, when Mobdev runs from `swift build`.
    static var cacheFolder: URL {
        // Sources/MobdevCore/Emulators/ScrcpyServer.swift → macos/.build
        var folder = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { folder.deleteLastPathComponent() }
        return folder.appendingPathComponent(".build", isDirectory: true)
    }

    private static func locate() async -> Result<URL, DeveloperError> {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: bundled.path) {
                return isIntact(bundled) ? .success(bundled) : .failure(DeveloperError("\(bundled.path) is damaged."))
            }
        }
        // The app carries the server; only builds outside an app bundle fetch it.
        guard Bundle.main.bundleURL.pathExtension != "app" else {
            return .failure(DeveloperError("The app has no \(fileName) in its Resources."))
        }
        let cached = cacheFolder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: cached.path), isIntact(cached) { return .success(cached) }
        do {
            let (data, response) = try await URLSession.shared.data(from: downloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200, digest(data) == sha256 else {
                return .failure(DeveloperError("The download of \(fileName) from GitHub failed or did not match its checksum."))
            }
            try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
            try data.write(to: cached, options: .atomic)
            Log.info("downloaded \(fileName) to \(cached.path)")
            return .success(cached)
        } catch {
            return .failure(DeveloperError("Could not download \(fileName): \(error.localizedDescription)"))
        }
    }

    static func isIntact(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return digest(data) == sha256
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
