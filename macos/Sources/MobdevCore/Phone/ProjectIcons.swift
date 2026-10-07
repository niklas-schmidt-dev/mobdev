import Foundation
import ImageIO

/// A project's icon, found the way T3 Code finds a project's favicon: an image file the user
/// chose, else the app's own icon from the repository. The app keeps the choice in its settings,
/// not in mobdev.json, which older Mobdev versions read strictly.
public enum ProjectIcons {
    /// Image files an icon may be.
    public static let fileExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "ico", "icns", "tiff", "svg"]

    /// Where web projects keep a favicon or logo, after T3 Code's list, and the default icon
    /// paths of Expo and flutter_launcher_icons; at the repository's root or, in a monorepo, in
    /// a folder of it such as apps/web.
    static let commonFiles = [
        "favicon.svg", "favicon.ico", "favicon.png",
        "public/favicon.svg", "public/favicon.ico", "public/favicon.png",
        "app/favicon.ico", "app/favicon.png", "app/icon.svg", "app/icon.png", "app/icon.ico",
        "src/favicon.ico", "src/favicon.svg", "src/app/favicon.ico", "src/app/icon.svg", "src/app/icon.png",
        "assets/images/icon.png", "assets/icon/icon.png", "assets/icon.svg", "assets/icon.png",
        "assets/logo.svg", "assets/logo.png", ".idea/icon.svg",
    ]

    /// Folders the search never enters: dependencies, build output and Mobdev's own output.
    static let skippedFolders: Set<String> = [
        "node_modules", "Pods", "Carthage", "vendor", "build", "Build", "DerivedData", "dist", "out", "output",
        "intermediates", "generated", "tmp", "fastlane", "screenshots", "baselines",
    ]

    /// How deep and how far the search looks, so a large repository stays quick.
    static let maxDepth = 10
    static let maxEntries = 40_000

    /// The repository a project lives in: the nearest folder at or above it with .git, else the
    /// folder above a project named mobdev, else the project's own folder.
    public static func repository(of project: URL) -> URL {
        let start = ProjectList.normalized(project)
        var folder = start
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return folder }
            folder.deleteLastPathComponent()
        }
        return start.lastPathComponent == TestProject.defaultFolderName ? start.deletingLastPathComponent() : start
    }

    /// The images in a repository that could be the app's icon, the likeliest first: the icon in
    /// an Expo app.json, the largest picture of an iOS AppIcon set, Android's launcher icon at its
    /// highest density, then a favicon or logo where web projects keep one.
    public static func candidates(in repository: URL) -> [URL] {
        let root = ProjectList.normalized(repository)
        var expo: [URL] = []
        var appIconSets: [URL] = []
        var launchers: [URL] = []
        var common: [(rank: Int, depth: Int, url: URL)] = []
        let prefix = root.path + "/"
        walk(root) { url, isFolder in
            if isFolder {
                if url.pathExtension == "appiconset" { appIconSets.append(url) }
                return
            }
            let name = url.lastPathComponent
            let relative = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : name
            if let rank = commonFiles.firstIndex(where: { relative == $0 || relative.hasSuffix("/" + $0) }) {
                common.append((rank, relative.split(separator: "/").count, url))
            }
            if name == "app.json" {
                expo += expoIcons(in: url)
            } else if url.deletingLastPathComponent().lastPathComponent.hasPrefix("mipmap-"),
                name.hasPrefix("ic_launcher"), ["png", "webp"].contains(url.pathExtension.lowercased())
            {
                launchers.append(url)
            }
        }
        var found = expo
        // A set named AppIcon before AppIcon-Dev and the like; in a set, the largest picture.
        for set in appIconSets.sorted(by: { rank(appIconSet: $0) < rank(appIconSet: $1) }) {
            if let largest = largestImage(in: set) { found.append(largest) }
        }
        found += launchers.sorted { rank(launcher: $0) < rank(launcher: $1) }
        found += common.sorted { ($0.depth, $0.rank, $0.url.path) < ($1.depth, $1.rank, $1.url.path) }.map(\.url)
        var unique: [URL] = []
        for url in found.map({ $0.standardizedFileURL }) where !unique.contains(url) { unique.append(url) }
        return Array(unique.prefix(12))
    }

    /// Whether a file can be a project's icon, by its extension.
    public static func isImage(_ url: URL) -> Bool { fileExtensions.contains(url.pathExtension.lowercased()) }

    // MARK: Search

    private static func walk(_ root: URL, visit: (URL, Bool) -> Void) {
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }
        var seen = 0
        while let url = walker.nextObject() as? URL {
            seen += 1
            if seen > maxEntries { return }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder {
                if skippedFolders.contains(url.lastPathComponent) || walker.level >= maxDepth {
                    walker.skipDescendants()
                    if skippedFolders.contains(url.lastPathComponent) { continue }
                }
            }
            visit(url, isFolder)
        }
    }

    /// The icons an Expo app.json names: expo.icon, then the iOS and Android ones.
    static func expoIcons(in file: URL) -> [URL] {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let expo = object["expo"] as? [String: Any]
        else { return [] }
        let paths = [expo["icon"], (expo["ios"] as? [String: Any])?["icon"], (expo["android"] as? [String: Any])?["icon"]]
            .compactMap { $0 as? String }
        return paths.map { file.deletingLastPathComponent().appendingPathComponent($0).standardizedFileURL }
            .filter { isImage($0) && FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func rank(appIconSet url: URL) -> (Int, String) {
        let name = url.deletingPathExtension().lastPathComponent
        let inTests = url.path.contains("Tests/") || url.path.contains("UITests")
        return ((name == "AppIcon" ? 0 : name.hasPrefix("AppIcon") ? 1 : 2) + (inTests ? 3 : 0), url.path)
    }

    private static let densities = ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi", "ldpi"]

    /// main before debug and other source sets, the highest density first, the plain icon before the round one.
    private static func rank(launcher url: URL) -> (Int, Int, Int, String) {
        let folder = url.deletingLastPathComponent().lastPathComponent
        let density = densities.firstIndex { folder.contains("-\($0)") } ?? densities.count
        let round = url.lastPathComponent.contains("round") || url.lastPathComponent.contains("foreground") ? 1 : 0
        return (url.path.contains("/src/main/") ? 0 : 1, density, round, url.path)
    }

    /// The picture with the most pixels in an asset catalog's icon set.
    static func largestImage(in set: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: set, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .map { ($0, pixelWidth($0)) }
            .max { $0.1 < $1.1 }?.0
    }

    private static func pixelWidth(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return 0 }
        return properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    }
}
