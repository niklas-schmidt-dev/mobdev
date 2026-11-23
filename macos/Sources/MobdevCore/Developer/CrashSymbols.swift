import Foundation

/// Names the frames of a crash report with function, file and line, from symbols on this Mac.
///
/// An image's symbols are found by its UUID: a dSYM through Spotlight
/// (`mdfind "com_apple_xcode_dsym_uuids == <UUID>"`, which also finds Xcode's archives), else a
/// dSYM or the built binary in the product folders, such as Xcode's DerivedData. A Debug build has
/// no dSYM by default; its binary points `atos` to the object files, which have the lines. Every
/// candidate's UUID is read from the file before it is used, so a stale build is never used.
/// `atos` runs once per image with all of its addresses. Everything together takes at most
/// `budget` seconds; whatever is not found in time, or fails, stays as the report printed it.
struct CrashSymbolicator: Sendable {
    let runner: CommandRunning
    /// Folders that hold built apps and their dSYMs side by side, read only when Spotlight finds
    /// nothing.
    let productFolders: @Sendable () -> [URL]
    var budget: TimeInterval = 15
    /// At most this many images are looked up per report.
    var maxImages = 8

    static let mdfind = URL(fileURLWithPath: "/usr/bin/mdfind")
    static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    /// Xcode's DerivedData products in `developer` (`~/Library/Developer`:
    /// `Xcode/DerivedData/<project>/Build/Products/Debug-iphoneos`…) and, for a simulator, the
    /// folders its installed apps are in, whose binaries are the ones that crashed.
    static func productFolders(developer: URL, simulator udid: String?) -> [URL] {
        let manager = FileManager.default
        func folders(in folder: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        var found: [URL] = []
        if let udid {
            found += folders(
                in: developer.appendingPathComponent("CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application"))
        }
        for project in folders(in: developer.appendingPathComponent("Xcode/DerivedData")) {
            found += folders(in: project.appendingPathComponent("Build/Products"))
        }
        return found
    }

    func symbolicate(_ report: CrashReport) async -> CrashReport {
        var report = report
        let deadline = Date().addingTimeInterval(budget)
        var images: [CrashReport.Image] = []
        for address in report.addresses where !images.contains(address.image) { images.append(address.image) }
        // Listed once, and only when Spotlight does not know an image.
        var folders: [URL]?
        func listed() -> [URL] {
            if folders == nil { folders = productFolders() }
            return folders ?? []
        }
        for image in images.prefix(maxImages) {
            guard Date() < deadline, let file = await symbolFile(for: image, deadline: deadline, folders: listed)
            else { continue }
            let addresses = report.addresses.filter { $0.image == image }
            guard let symbols = await atos(file, image: image, addresses: addresses.map(\.address), deadline: deadline)
            else { continue }
            var named = false
            for (address, symbol) in zip(addresses, symbols) {
                guard let symbol else { continue }
                report.frames[address.frame] =
                    "\(address.frame)  \(image.name)  " + String(format: "0x%016llx", address.address) + "  \(symbol)"
                named = true
            }
            if named, !report.symbolFiles.contains(file.symbols.path) { report.symbolFiles.append(file.symbols.path) }
        }
        return report
    }

    /// A file `atos` reads for the image, and the dSYM or binary it belongs to, for the report.
    struct SymbolFile: Sendable, Equatable {
        var file: URL
        var symbols: URL
    }

    func symbolFile(for image: CrashReport.Image, deadline: Date, folders: () -> [URL]) async -> SymbolFile? {
        let manager = FileManager.default
        if let result = try? await runner.run(
            Self.mdfind, ["com_apple_xcode_dsym_uuids == \(image.uuid)"], timeout: min(5, deadline.timeIntervalSinceNow)),
            result.status == 0
        {
            for line in result.output.split(separator: "\n") where line.hasPrefix("/") {
                let dSYM = URL(fileURLWithPath: String(line))
                if let file = Self.dwarfFiles(in: dSYM).first(where: { MachO.uuids(of: $0).contains(image.uuid) }) {
                    return SymbolFile(file: file, symbols: dSYM)
                }
            }
        }
        guard Date() < deadline else { return nil }
        // A dSYM next to the build, then the binary itself: a Debug build has no dSYM.
        let folders = folders()
        var candidates: [SymbolFile] = []
        for folder in folders {
            let items = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for dSYM in items where dSYM.pathExtension == "dSYM" {
                let file = dSYM.appendingPathComponent("Contents/Resources/DWARF/\(image.name)")
                candidates.append(SymbolFile(file: file, symbols: dSYM))
            }
        }
        if let inBundle = Self.pathInBundle(image.path) {
            for folder in folders {
                let file = folder.appendingPathComponent(inBundle)
                candidates.append(SymbolFile(file: file, symbols: file))
            }
        }
        return candidates.first { candidate in
            // Reading many builds, or a slow volume, must not outlast the budget.
            Date() < deadline && manager.fileExists(atPath: candidate.file.path)
                && MachO.uuids(of: candidate.file).contains(image.uuid)
        }
    }

    /// The image's path from its app bundle on, "MyApp.app/Frameworks/Kit.framework/Kit", which is
    /// where it is in the folder the app was built into. Nil outside an app.
    static func pathInBundle(_ path: String?) -> String? {
        guard let parts = path?.split(separator: "/").map(String.init),
            let app = parts.firstIndex(where: { $0.hasSuffix(".app") }), app < parts.count - 1,
            !parts[app...].contains(".."), !parts[app...].contains(where: { $0.contains("*") })
        else { return nil }
        return parts[app...].joined(separator: "/")
    }

    /// The DWARF files of a dSYM bundle; the file itself when it is not one.
    static func dwarfFiles(in dSYM: URL) -> [URL] {
        let folder = dSYM.appendingPathComponent("Contents/Resources/DWARF")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.isEmpty ? [dSYM] : files.sorted { $0.path < $1.path }
    }

    /// What `atos` says for each address, in order; nil for one it could not name, and nil for all
    /// when it failed or printed something else than one answer per address.
    func atos(_ file: SymbolFile, image: CrashReport.Image, addresses: [UInt64], deadline: Date) async -> [String?]? {
        let timeout = min(15, deadline.timeIntervalSinceNow)
        guard timeout > 0 else { return nil }
        let arguments =
            ["atos", "-arch", image.arch, "-o", file.file.path, "-l", String(format: "0x%llx", image.base)]
            + addresses.map { String(format: "0x%llx", $0) }
        guard let result = try? await runner.run(Self.xcrun, arguments, timeout: timeout), result.status == 0 else {
            return nil
        }
        // Standard error comes along: warnings are left out, and an answer is an address it
        // could not name or a name "(in Image)".
        let answers = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("0x") || $0.contains(" (in ") }
        guard answers.count == addresses.count else { return nil }
        return answers.map { answer in
            guard !answer.hasPrefix("0x"), let image = answer.range(of: #" \(in [^)]*\)"#, options: .regularExpression)
            else { return nil }
            var symbol = answer
            symbol.removeSubrange(image)
            return symbol
        }
    }
}

/// Reads the UUIDs of a Mach-O file, the identity `atos` and Spotlight match a crash's images by.
enum MachO {
    /// One per architecture of a universal file, upper case with dashes; empty when the file is not
    /// Mach-O.
    static func uuids(of file: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data? {
            guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count),
                data.count == count
            else { return nil }
            return data
        }
        guard let magic = read(0, 4)?.uint32(at: 0, bigEndian: true) else { return [] }
        // A universal file: a big-endian table of the slices and where each starts.
        if magic == 0xcafe_babe || magic == 0xcafe_babf {
            let wide = magic == 0xcafe_babf
            guard let count = read(4, 4)?.uint32(at: 0, bigEndian: true), count <= 32 else { return [] }
            let size = wide ? 32 : 20
            return (0..<Int(count)).flatMap { index -> [String] in
                guard let entry = read(8 + UInt64(index * size), size) else { return [] }
                let offset = wide ? entry.uint64(at: 8, bigEndian: true) : UInt64(entry.uint32(at: 8, bigEndian: true))
                return uuid(at: offset, read: read).map { [$0] } ?? []
            }
        }
        return uuid(at: 0, read: read).map { [$0] } ?? []
    }

    /// LC_UUID of the slice at `offset`, from its little-endian header and load commands.
    private static func uuid(at offset: UInt64, read: (UInt64, Int) -> Data?) -> String? {
        guard let header = read(offset, 28) else { return nil }
        let magic = header.uint32(at: 0)
        guard magic == 0xfeed_facf || magic == 0xfeed_face else { return nil }
        let commands = Int(header.uint32(at: 16))
        let size = Int(header.uint32(at: 20))
        guard size <= 16_000_000, let table = read(offset + (magic == 0xfeed_facf ? 32 : 28), size) else { return nil }
        var position = 0
        for _ in 0..<commands {
            guard position + 8 <= table.count else { return nil }
            let command = table.uint32(at: position)
            let length = Int(table.uint32(at: position + 4))
            guard length >= 8 else { return nil }
            if command == 0x1b, length >= 24, position + 24 <= table.count {
                let bytes = table[(table.startIndex + position + 8)..<(table.startIndex + position + 24)]
                return CrashReport.uuid(bytes.map { String(format: "%02X", $0) }.joined())
            }
            position += length
        }
        return nil
    }
}

extension Data {
    fileprivate func uint32(at offset: Int, bigEndian: Bool = false) -> UInt32 {
        let bytes = self[(startIndex + offset)..<(startIndex + offset + 4)]
        let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return bigEndian ? value : value.byteSwapped
    }

    fileprivate func uint64(at offset: Int, bigEndian: Bool) -> UInt64 {
        let bytes = self[(startIndex + offset)..<(startIndex + offset + 8)]
        let value = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return bigEndian ? value : value.byteSwapped
    }
}
