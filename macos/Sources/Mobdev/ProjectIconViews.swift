import AppKit
import MobdevCore
import SwiftUI
import UniformTypeIdentifiers

/// Project icons, as T3 Code shows them: the image file chosen for a project, else the app icon
/// found in its repository (`ProjectIcons`), else a folder. Searching and drawing happen off the
/// main thread; the results stay for the app's lifetime.
@MainActor @Observable
final class ProjectIconStore {
    static let shared = ProjectIconStore()

    /// The icons found in each repository, by its path; missing until searched.
    private(set) var found: [String: [URL]] = [:]
    /// Drawn icons, by file and size.
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var repositories: [String: URL] = [:]
    @ObservationIgnored private var searching: Set<String> = []
    @ObservationIgnored private var drawing: Set<String> = []

    func repository(of folder: URL) -> URL {
        if let known = repositories[folder.path] { return known }
        let repository = ProjectIcons.repository(of: folder)
        repositories[folder.path] = repository
        return repository
    }

    func candidates(for folder: URL) -> [URL]? { found[repository(of: folder).path] }

    /// Looks for icons in the project's repository, once unless `again`.
    func search(_ folder: URL, again: Bool = false) async {
        let repository = repository(of: folder)
        let key = repository.path
        guard again || found[key] == nil, !searching.contains(key) else { return }
        searching.insert(key)
        let result = await Task.detached(priority: .utility) { ProjectIcons.candidates(in: repository) }.value
        searching.remove(key)
        found[key] = result
        if again { images = images.filter { entry in !result.contains { entry.key.hasPrefix($0.path + "|") } } }
    }

    func image(_ file: URL, pixels: Int) -> NSImage? { images["\(file.path)|\(pixels)"] }

    /// Draws an icon file at `pixels` square, unless it is drawn already.
    func draw(_ file: URL, pixels: Int) async {
        let key = "\(file.path)|\(pixels)"
        guard images[key] == nil, !drawing.contains(key) else { return }
        drawing.insert(key)
        let data = await Task.detached(priority: .utility) { Self.png(of: file, pixels: pixels) }.value
        drawing.remove(key)
        if let data, let image = NSImage(data: data) { images[key] = image }
    }

    /// Draws `file` again next time, after it was chosen anew.
    func forget(_ file: URL) { images = images.filter { !$0.key.hasPrefix(file.path + "|") } }

    /// A short name for an icon file in the menu: what it is for, or its path in the repository.
    static func title(of file: URL, in repository: URL) -> String {
        let parent = file.deletingLastPathComponent()
        if parent.pathExtension == "appiconset" { return "\(parent.deletingPathExtension().lastPathComponent) (iOS)" }
        if parent.lastPathComponent.hasPrefix("mipmap-") {
            let density = parent.lastPathComponent.dropFirst("mipmap-".count)
            return "\(file.deletingPathExtension().lastPathComponent) (Android, \(density))"
        }
        let base = repository.path + "/"
        return file.path.hasPrefix(base) ? String(file.path.dropFirst(base.count)) : file.lastPathComponent
    }

    /// The file as a square PNG of `pixels`, fitted and centred: ImageIO for bitmaps, taking the
    /// largest picture of an .ico or .icns, and AppKit for SVG.
    nonisolated static func png(of file: URL, pixels: Int) -> Data? {
        let image: NSImage
        if file.pathExtension.lowercased() == "svg" {
            guard let svg = NSImage(contentsOf: file) else { return nil }
            image = svg
        } else {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
            let largest = (0..<CGImageSourceGetCount(source)).max { index, other in
                width(source, index) < width(source, other)
            } ?? 0
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, largest, options) else { return nil }
            image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        }
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = CGFloat(pixels) / max(size.width, size.height)
        let fitted = NSRect(
            x: (CGFloat(pixels) - size.width * scale) / 2, y: (CGFloat(pixels) - size.height * scale) / 2,
            width: size.width * scale, height: size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: fitted, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private nonisolated static func width(_ source: CGImageSource, _ index: Int) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    }
}

/// A project's icon at `size` points: its image with rounded corners, else a folder.
struct ProjectIconView: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    var size: CGFloat = 16
    var active = false
    private let store = ProjectIconStore.shared

    /// The file the icon shows: the chosen one while it exists, else the first one found.
    private var file: URL? {
        switch model.projectIconChoice(folder) {
        case .none: nil
        case .file(let url) where FileManager.default.fileExists(atPath: url.path): url
        case .file, .automatic: store.candidates(for: folder)?.first
        }
    }

    private var pixels: Int { Int((size * 2).rounded(.up)) }

    var body: some View {
        Group {
            if let file, let image = store.image(file, pixels: pixels) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
            } else {
                Image(systemName: active ? "folder.fill" : "folder")
                    .font(size > 24 ? .system(size: size * 0.6) : nil)
                    .frame(width: size > 24 ? size : nil, height: size > 24 ? size : nil)
            }
        }
        .task(id: folder.path) { await store.search(folder) }
        .task(id: "\(file?.path ?? "") \(pixels)") {
            if let file { await store.draw(file, pixels: pixels) }
        }
    }
}

/// The icon choices of a project, for its context menu and its overview: the app icon found by
/// itself, each image found in the repository, a file of your own, or none.
struct ProjectIconMenuItems: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    private let store = ProjectIconStore.shared

    var body: some View {
        let repository = store.repository(of: folder)
        let found = store.candidates(for: folder) ?? []
        let choice = model.projectIconChoice(folder)
        Picker("Icon", selection: Binding(get: { choice }, set: { model.setProjectIcon(folder, $0) })) {
            Text(found.first.map { "Automatic: \(ProjectIconStore.title(of: $0, in: repository))" } ?? "Automatic")
                .tag(AppModel.ProjectIconChoice.automatic)
            ForEach(found, id: \.self) { url in
                Text(ProjectIconStore.title(of: url, in: repository)).tag(AppModel.ProjectIconChoice.file(url))
            }
            if case .file(let url) = choice, !found.contains(url) {
                Text(ProjectIconStore.title(of: url, in: repository)).tag(choice)
            }
            Text("No Icon").tag(AppModel.ProjectIconChoice.none)
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Button("Choose Image File…") { chooseFile(in: repository) }
        Button("Look for Icons Again") { Task { await store.search(folder, again: true) } }
    }

    private func chooseFile(in repository: URL) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ProjectIcons.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = repository
        panel.prompt = "Use as Icon"
        panel.message = "Choose an image for the project's icon, such as the app icon or a logo."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.forget(url)
        model.setProjectIcon(folder, .file(url))
    }
}
