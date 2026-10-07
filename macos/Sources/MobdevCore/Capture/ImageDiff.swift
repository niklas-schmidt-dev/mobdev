import CoreGraphics
import Foundation
import ImageIO

/// An image as 8-bit RGBA bytes in sRGB, rows from the top, for comparing and measuring pixels.
struct PixelBuffer: Sendable {
    let width: Int
    let height: Int
    /// R, G, B, A for each pixel, row by row.
    var bytes: [UInt8]

    /// The image drawn at `width`×`height` (its own size by default).
    init?(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
        let width = width ?? image.width, height = height ?? image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    var image: CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// How a screen differs from a baseline of the same size.
struct ImageComparison: Sendable {
    let width: Int
    let height: Int
    /// Pixels that count as changed: different beyond the tolerance, more than a moved edge, with
    /// changed neighbors.
    let changedPixels: Int
    /// Pixels outside the masks.
    let comparedPixels: Int
    /// Per pixel: 0 the same, 1 a tolerated difference (antialiasing, compression), 2 changed, 3 masked.
    let states: [UInt8]
    /// Where the changes are, largest first, in pixels from the top-left.
    let regions: [CGRect]

    /// The share of compared pixels that changed, 0 to 1.
    var changedShare: Double { comparedPixels == 0 ? 0 : Double(changedPixels) / Double(comparedPixels) }
}

/// Compares screenshots the way a visual regression test should: robust to the noise of
/// antialiasing, scaling and compression, yet strict about anything a person would notice, such as
/// a moved button or changed text. A pixel counts as changed when its color differs beyond
/// `tolerance`, is not the other picture moved by up to a pixel, and has changed neighbors.
enum ImageDiff {
    /// How different two pixels may be and still count as the same, as pixelmatch measures it: a
    /// distance in the YIQ color space, 0 to 1. 0.1 lets through noise of about 10% in brightness.
    static let tolerance = 0.1
    /// A changed pixel counts only with at least this many changed neighbors of its eight, so
    /// isolated pixels and one-pixel lines, which compression and edges make, do not; anything two
    /// pixels wide does.
    static let neighbors = 3
    /// Changes are grouped into regions on a grid of this many pixels.
    static let regionCell = 16

    /// Compares two images of the same size. `masks` (pixels from the top-left) are left out.
    static func compare(_ actual: PixelBuffer, _ expected: PixelBuffer, masks: [CGRect] = []) -> ImageComparison {
        precondition(actual.width == expected.width && actual.height == expected.height)
        let width = actual.width, height = actual.height
        var states = [UInt8](repeating: 0, count: width * height)
        for mask in masks {
            let rect = mask.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !rect.isNull, !rect.isEmpty else { continue }
            for y in Int(rect.minY.rounded(.down))..<Int(rect.maxY.rounded(.up)) {
                for x in Int(rect.minX.rounded(.down))..<Int(rect.maxX.rounded(.up)) { states[y * width + x] = 3 }
            }
        }
        let limit = 35215 * tolerance * tolerance
        /// The YIQ distance of pixel `i` of `a` and pixel `j` of `b`, squared, as pixelmatch has it.
        func distance(_ a: UnsafeBufferPointer<UInt8>, _ i: Int, _ b: UnsafeBufferPointer<UInt8>, _ j: Int) -> Double {
            let dr = Double(a[i * 4]) - Double(b[j * 4])
            let dg = Double(a[i * 4 + 1]) - Double(b[j * 4 + 1])
            let db = Double(a[i * 4 + 2]) - Double(b[j * 4 + 2])
            let y = dr * 0.29889531 + dg * 0.58662247 + db * 0.11448223
            let i = dr * 0.59597799 - dg * 0.27417610 - db * 0.32180189
            let q = dr * 0.21147017 - dg * 0.52261711 + db * 0.31114694
            return 0.5053 * y * y + 0.299 * i * i + 0.1957 * q * q
        }
        /// Whether pixel `index` of `a` could be `b` moved by up to a pixel: its color is within a
        /// pixel of the same place in `b`, or a blend of the colors there, as an edge moved by part
        /// of a pixel is.
        func nearby(_ a: UnsafeBufferPointer<UInt8>, _ index: Int, in b: UnsafeBufferPointer<UInt8>) -> Bool {
            let x = index % width, y = index / width
            var low: (Int, Int, Int) = (255, 255, 255), high: (Int, Int, Int) = (0, 0, 0)
            for ny in max(y - 1, 0)...min(y + 1, height - 1) {
                for nx in max(x - 1, 0)...min(x + 1, width - 1) {
                    let other = ny * width + nx
                    if distance(a, index, b, other) <= limit { return true }
                    let r = Int(b[other * 4]), g = Int(b[other * 4 + 1]), bl = Int(b[other * 4 + 2])
                    low = (min(low.0, r), min(low.1, g), min(low.2, bl))
                    high = (max(high.0, r), max(high.1, g), max(high.2, bl))
                }
            }
            let margin = 8
            let r = Int(a[index * 4]), g = Int(a[index * 4 + 1]), bl = Int(a[index * 4 + 2])
            return (low.0 - margin...high.0 + margin).contains(r) && (low.1 - margin...high.1 + margin).contains(g)
                && (low.2 - margin...high.2 + margin).contains(bl)
        }
        // 1 marks a difference, 4 one that is more than an edge moved by up to a pixel either way,
        // as antialiasing and scaling move them.
        actual.bytes.withUnsafeBufferPointer { a in
            expected.bytes.withUnsafeBufferPointer { b in
                for index in 0..<(width * height) where states[index] == 0 && distance(a, index, b, index) > limit {
                    states[index] = nearby(a, index, in: b) && nearby(b, index, in: a) ? 1 : 4
                }
            }
        }
        // Differences with enough differing neighbors are changes; the rest is noise.
        var changed: [Int] = []
        for y in 0..<height {
            for x in 0..<width where states[y * width + x] == 4 {
                var count = 0
                for ny in max(y - 1, 0)...min(y + 1, height - 1) {
                    for nx in max(x - 1, 0)...min(x + 1, width - 1) where (nx != x || ny != y) {
                        if states[ny * width + nx] == 4 { count += 1 }
                    }
                }
                if count >= neighbors { changed.append(y * width + x) }
            }
        }
        for index in states.indices where states[index] == 4 { states[index] = 1 }
        for index in changed { states[index] = 2 }
        let masked = states.reduce(0) { $0 + ($1 == 3 ? 1 : 0) }
        return ImageComparison(
            width: width, height: height, changedPixels: changed.count, comparedPixels: width * height - masked,
            states: states, regions: regions(changed, width: width, height: height))
    }

    /// The changed pixels grouped into touching cells of the grid, as rectangles, the ones with
    /// the most changed pixels first.
    private static func regions(_ changed: [Int], width: Int, height: Int) -> [CGRect] {
        let cell = regionCell
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var counts = [Int](repeating: 0, count: columns * rows)
        for index in changed { counts[(index / width / cell) * columns + (index % width) / cell] += 1 }
        var seen = [Bool](repeating: false, count: counts.count)
        var found: [(rect: CGRect, count: Int)] = []
        for start in counts.indices where counts[start] > 0 && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minColumn = Int.max, maxColumn = 0, minRow = Int.max, maxRow = 0, total = 0
            while let current = stack.popLast() {
                let column = current % columns, row = current / columns
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
                total += counts[current]
                for nextRow in max(row - 1, 0)...min(row + 1, rows - 1) {
                    for nextColumn in max(column - 1, 0)...min(column + 1, columns - 1) {
                        let next = nextRow * columns + nextColumn
                        if counts[next] > 0, !seen[next] {
                            seen[next] = true
                            stack.append(next)
                        }
                    }
                }
            }
            let rect = CGRect(
                x: minColumn * cell, y: minRow * cell, width: (maxColumn - minColumn + 1) * cell,
                height: (maxRow - minRow + 1) * cell
            ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            found.append((rect, total))
        }
        return found.sorted { $0.count > $1.count }.map(\.rect)
    }

    /// The actual screen faded to light gray, with changed pixels in red, tolerated differences in
    /// yellow, masked areas tinted blue and a box around each changed region.
    static func picture(of comparison: ImageComparison, over actual: PixelBuffer) -> CGImage? {
        var bytes = actual.bytes
        for index in 0..<(comparison.width * comparison.height) {
            let offset = index * 4
            let gray = 0.299 * Double(bytes[offset]) + 0.587 * Double(bytes[offset + 1]) + 0.114 * Double(bytes[offset + 2])
            let faded = UInt8(255 - (255 - gray) * 0.3)
            var color: (UInt8, UInt8, UInt8)
            switch comparison.states[index] {
            case 2: color = (255, 0, 64)
            case 1: color = (255, 200, 0)
            case 3: color = (UInt8(Double(faded) * 0.75), UInt8(Double(faded) * 0.75 + 30), 255)
            default: color = (faded, faded, faded)
            }
            bytes[offset] = color.0
            bytes[offset + 1] = color.1
            bytes[offset + 2] = color.2
            bytes[offset + 3] = 255
        }
        guard let base = PixelBuffer(width: comparison.width, height: comparison.height, bytes: bytes).image,
            let context = CGContext(
                data: nil, width: comparison.width, height: comparison.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let height = Double(comparison.height)
        context.draw(base, in: CGRect(x: 0, y: 0, width: comparison.width, height: comparison.height))
        context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0.25, alpha: 1))
        context.setLineWidth(2)
        for region in comparison.regions.prefix(20) {
            // Core Graphics counts from the bottom.
            let box = CGRect(x: region.minX, y: height - region.maxY, width: region.width, height: region.height)
            context.stroke(box.insetBy(dx: -2, dy: -2))
        }
        return context.makeImage()
    }

    /// A PNG or JPEG file as an image.
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
