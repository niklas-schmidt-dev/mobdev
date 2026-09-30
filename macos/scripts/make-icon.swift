// Packages the Imagegen master artwork on a transparent 1024 px macOS icon canvas.
// The artwork includes its rounded tile and margin; 944 px places the tile near the 824 px grid.
// --dev selects the amber master, keeping development builds visually distinct.
//   swift scripts/make-icon.swift Resources/AppIcon.png
//   swift scripts/make-icon.swift --dev Resources/AppIconDev.png
import AppKit

let arguments = CommandLine.arguments.dropFirst()
let dev = arguments.contains("--dev")
let output = arguments.first { !$0.hasPrefix("--") } ?? "AppIcon.png"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("assets/branding/\(dev ? "mobdev-dev" : "mobdev").png")
guard let data = try? Data(contentsOf: source),
    let image = NSBitmapImageRep(data: data)?.cgImage,
    let space = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
        data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("Could not load branding master at \(source.path)") }

context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 40, y: 40, width: 944, height: 944))
let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
