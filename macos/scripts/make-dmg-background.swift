// Renders the background of the Mobdev disk image window, Resources/DMGBackground.png (660 × 400)
// and DMGBackground@2x.png: a light glass card with a dotted arrow from the app to Applications.
// Finder draws the two icons and their names on top, at the positions in scripts/dmg-settings.py.
//   swift scripts/make-dmg-background.swift Resources/DMGBackground.png
import AppKit

let width = 660.0
let height = 400.0
/// Icon centers, shared with scripts/dmg-settings.py.
let app = CGPoint(x: 175, y: 190)
let applications = CGPoint(x: 485, y: 190)

let output = CommandLine.arguments.dropFirst().first ?? "DMGBackground.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
}

func render(scale: Double) -> NSBitmapImageRep {
    let context = CGContext(
        data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Top-left coordinates in points, like Finder's icon positions.
    context.translateBy(x: 0, y: height * scale)
    context.scaleBy(x: scale, y: -scale)

    // Background: a soft light gradient with a green glow behind the app and a faint blue one below Applications.
    let base = CGGradient(colorsSpace: space, colors: [color(0xFBFBFD), color(0xEFF0F3)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    func glow(_ hex: UInt32, _ alpha: Double, at center: CGPoint, radius: Double) {
        let gradient = CGGradient(
            colorsSpace: space, colors: [color(hex, alpha), color(hex, 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    glow(0xD1EDA5, 0.6, at: CGPoint(x: 150, y: 170), radius: 330)
    glow(0x0A84FF, 0.09, at: CGPoint(x: 560, y: 290), radius: 300)

    // The glass card behind both icons.
    let card = CGPath(
        roundedRect: CGRect(x: 40, y: 88, width: 580, height: 222), cornerWidth: 28, cornerHeight: 28, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -16 * scale), blur: 40 * scale, color: color(0x000000, 0.07))
    context.addPath(card)
    context.setFillColor(color(0xFFFFFF, 0.55))
    context.fillPath()
    context.restoreGState()
    context.addPath(card)
    context.setStrokeColor(color(0xFFFFFF, 0.95))
    context.setLineWidth(1)
    context.strokePath()

    // A dotted arc from the app to Applications, ending in an open arrowhead.
    let start = CGPoint(x: app.x + 82, y: app.y - 4)
    let end = CGPoint(x: applications.x - 84, y: applications.y - 6)
    context.setStrokeColor(color(0x86868B))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(3)
    context.setLineDash(phase: 0, lengths: [0.01, 9])
    let control = CGPoint(x: end.x - 50, y: end.y - 18)
    context.move(to: start)
    context.addCurve(to: end, control1: CGPoint(x: start.x + 40, y: start.y - 34), control2: control)
    context.strokePath()
    // The arrowhead points the way the curve ends, a little past its last dot.
    let length = hypot(end.x - control.x, end.y - control.y)
    let unit = CGPoint(x: (end.x - control.x) / length, y: (end.y - control.y) / length)
    let tip = CGPoint(x: end.x + unit.x * 7, y: end.y + unit.y * 7)
    func arm(_ angle: Double) -> CGPoint {
        CGPoint(
            x: tip.x - 15 * (unit.x * cos(angle) - unit.y * sin(angle)),
            y: tip.y - 15 * (unit.x * sin(angle) + unit.y * cos(angle)))
    }
    context.setLineDash(phase: 0, lengths: [])
    context.setLineWidth(2.5)
    context.move(to: arm(.pi / 5))
    context.addLine(to: tip)
    context.addLine(to: arm(-.pi / 5))
    context.strokePath()

    // Title and hint, in the system font.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    func text(_ string: String, size: Double, weight: NSFont.Weight, color: NSColor, kern: Double, y: Double) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern,
                .paragraphStyle: paragraph,
            ]
        ).draw(in: CGRect(x: 0, y: y, width: width, height: size * 1.6))
    }
    text("Install Mobdev", size: 22, weight: .semibold, color: NSColor(white: 0.114, alpha: 1), kern: -0.35, y: 32)
    text(
        "Drag Mobdev into Applications, then open it to connect your iPhone.", size: 12.5, weight: .regular,
        color: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1), kern: 0, y: 350)
    NSGraphicsContext.current = nil

    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    rep.size = NSSize(width: width, height: height)
    return rep
}

for (scale, path) in [(1.0, output), (2.0, output.replacingOccurrences(of: ".png", with: "@2x.png"))] {
    try! render(scale: scale).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
