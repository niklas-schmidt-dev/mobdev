// Renders Resources/AppIcon.png (1024 px) on the macOS 26 icon grid: an 824 px squircle
// with the Mobdev bars, a glass sheen and a soft shadow. --dev renders the amber icon of the
// development build, so it is never mistaken for the installed app.
//   swift scripts/make-icon.swift Resources/AppIcon.png
//   swift scripts/make-icon.swift --dev Resources/AppIconDev.png
import AppKit
import SwiftUI

let size = 1024.0
let arguments = CommandLine.arguments.dropFirst()
let dev = arguments.contains("--dev")
let output = arguments.first { !$0.hasPrefix("--") } ?? "AppIcon.png"
// Base, gradient top/middle/bottom, glow, bar top/bottom.
let palette: [UInt32] =
    dev
    ? [0x2A1C08, 0x5C3D12, 0x2A1C08, 0x140D04, 0xFFD58A, 0xFFF1D6, 0xFFB341]
    : [0x142017, 0x2A4A33, 0x142017, 0x0B130D, 0xD1EDA5, 0xEAF8CF, 0xB9E07F]
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in top-left coordinates like the SVG logo.
context.translateBy(x: 0, y: size)
context.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
}

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: tile).cgPath

// Shadow.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
context.addPath(squircle)
context.setFillColor(color(palette[0]))
context.fillPath()
context.restoreGState()

// Background gradient.
context.saveGState()
context.addPath(squircle)
context.clip()
let background = CGGradient(
    colorsSpace: space, colors: [color(palette[1]), color(palette[2]), color(palette[3])] as CFArray,
    locations: [0, 0.55, 1])!
context.drawLinearGradient(
    background, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
let glow = CGGradient(
    colorsSpace: space, colors: [color(palette[4], 0.28), color(palette[4], 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(
    glow, startCenter: CGPoint(x: 520, y: 470), startRadius: 0, endCenter: CGPoint(x: 520, y: 470), endRadius: 430,
    options: [])

// The bars from the logo (64 px viewBox, skewed by -12°), scaled onto the tile.
context.saveGState()
let scale = 824.0 / 64 * 0.92
context.translateBy(x: 512 - 32 * scale, y: 512 - 34 * scale)
context.scaleBy(x: scale, y: scale)
context.concatenate(CGAffineTransform(a: 1, b: tan(-12 * .pi / 180), c: 0, d: 1, tx: 0, ty: 0))
let bars = [CGRect(x: 16, y: 28, width: 8, height: 22), CGRect(x: 28, y: 20, width: 8, height: 34),
    CGRect(x: 40, y: 24, width: 8, height: 27)]
for bar in bars {
    context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
}
context.clip()
let barGradient = CGGradient(
    colorsSpace: space, colors: [color(palette[5]), color(palette[6])] as CFArray, locations: [0, 1])!
context.drawLinearGradient(barGradient, start: CGPoint(x: 0, y: 18), end: CGPoint(x: 0, y: 60), options: [])
context.restoreGState()

// Glass sheen on the upper half and a thin rim light.
let sheen = CGGradient(
    colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 520), options: [])
context.restoreGState()
context.addPath(squircle)
context.setStrokeColor(color(0xFFFFFF, 0.18))
context.setLineWidth(3)
context.strokePath()

let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
