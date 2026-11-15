// Draws the background of the DMG window: two dashed places for the icons and a streak of light
// that points from the app to the Applications folder, in the colours of the app icon.
//
//   swift scripts/dmg-background.swift            writes Resources/dmg-background.tiff (1x and 2x)
//   swift scripts/dmg-background.swift --preview  also writes build/dmg-preview.png,
//                                                 with the icons and labels where Finder puts them
//
// The numbers in `Layout` are also in scripts/dmg.sh. Change them in both.
import AppKit

enum Layout {
    static let width: CGFloat = 640
    static let height: CGFloat = 400
    static let iconSize: CGFloat = 112
    /// The centres of the icons, from the top left of the window, as Finder counts.
    static let app = CGPoint(x: 176, y: 176)
    static let applications = CGPoint(x: 464, y: 176)
    /// The middle of the label that Finder draws below an icon, at its smallest text size.
    static let finderLabelOffset: CGFloat = iconSize / 2 + 11
    /// The middle of the white label that is part of the picture, below the label of Finder.
    static let labelOffset: CGFloat = iconSize / 2 + 31
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let glowBlue: UInt32 = 0x3d5cff
let coreLight: UInt32 = 0xe6edff

/// A context in points with the origin at the top left, like the Finder window.
func makeContext(scale: CGFloat) -> CGContext {
    let context = CGContext(
        data: nil,
        width: Int(Layout.width * scale),
        height: Int(Layout.height * scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: Layout.height * scale)
    context.scaleBy(x: scale, y: -scale)
    return context
}

/// A thin lens of light with a glow. It is thickest at `peak` (0 = left end, 1 = right end).
func streak(
    _ context: CGContext, scale: CGFloat,
    from x0: CGFloat, to x1: CGFloat, y: CGFloat,
    thickness: CGFloat, peak: CGFloat, alpha: CGFloat, glow: CGFloat
) {
    let peakX = x0 + (x1 - x0) * peak
    let half = thickness / 2
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x0, y: y))
    path.addQuadCurve(to: CGPoint(x: x1, y: y), control: CGPoint(x: peakX, y: y - half * 2))
    path.addQuadCurve(to: CGPoint(x: x0, y: y), control: CGPoint(x: peakX, y: y + half * 2))
    path.closeSubpath()

    context.saveGState()
    // The blur of a shadow is in pixels, not in points.
    context.setShadow(offset: .zero, blur: glow * scale, color: color(glowBlue, min(1, alpha * 1.2)))
    context.setFillColor(color(coreLight, alpha))
    // Two times, for a glow that is strong near the core.
    context.addPath(path); context.fillPath()
    context.setShadow(offset: .zero, blur: glow * 0.35 * scale, color: color(0x7d95ff, alpha))
    context.addPath(path); context.fillPath()
    context.restoreGState()
}

func drawBackground(_ context: CGContext, scale: CGFloat) {
    let bounds = CGRect(x: 0, y: 0, width: Layout.width, height: Layout.height)
    let middle = CGPoint(x: Layout.width / 2, y: Layout.app.y)

    // The dark blue of the icon.
    let base = CGGradient(
        colorsSpace: space,
        colors: [color(0x0d1024), color(0x07081a)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: Layout.height), options: [])

    // A wide, weak glow behind the arrow.
    let haze = CGGradient(
        colorsSpace: space,
        colors: [color(glowBlue, 0.30), color(glowBlue, 0.10), color(glowBlue, 0)] as CFArray,
        locations: [0, 0.45, 1]
    )!
    context.saveGState()
    context.translateBy(x: middle.x, y: middle.y)
    context.scaleBy(x: 1, y: 0.62)
    context.drawRadialGradient(haze, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 330, options: [])
    context.restoreGState()

    // Weak streaks that go the same way as the arrow.
    context.saveGState()
    context.clip(to: bounds)
    let streaks: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        // x0, x1, y, thickness, alpha
        (-40, 260, 40, 1.6, 0.50),
        (310, 700, 60, 1.2, 0.32),
        (130, 500, 80, 1.0, 0.18),
        (-60, 200, 316, 1.2, 0.30),
        (220, 610, 336, 1.6, 0.46),
        (430, 720, 358, 1.0, 0.26),
        (50, 330, 376, 1.0, 0.18),
    ]
    for (x0, x1, y, thickness, alpha) in streaks {
        streak(context, scale: scale, from: x0, to: x1, y: y, thickness: thickness, peak: 0.75, alpha: alpha, glow: 10)
    }
    context.restoreGState()

    // The places of the two icons.
    for centre in [Layout.app, Layout.applications] {
        let slot = CGRect(x: centre.x - 78, y: centre.y - 78, width: 156, height: 184)
        let shape = CGPath(roundedRect: slot, cornerWidth: 28, cornerHeight: 28, transform: nil)
        context.saveGState()
        context.addPath(shape)
        // Dark, so the black label of Finder does not show on it. See `drawLabels`.
        context.setFillColor(color(0x030409, 0.94))
        context.fillPath()
        context.addPath(shape)
        context.setStrokeColor(color(0x9fb0ff, 0.38))
        context.setLineWidth(1.25)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [5, 6])
        context.strokePath()
        context.restoreGState()
    }

    drawLabels(context)

    // The arrow: the streak of light of the icon, on its side.
    let tail = Layout.app.x + 78 + 14
    let head = Layout.applications.x - 78 - 16
    streak(context, scale: scale, from: tail, to: head, y: middle.y, thickness: 4, peak: 0.82, alpha: 1, glow: 20)

    let point = CGPoint(x: head + 3, y: middle.y)
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: point.x - 9, y: point.y - 9))
    chevron.addLine(to: point)
    chevron.addLine(to: CGPoint(x: point.x - 9, y: point.y + 9))
    context.saveGState()
    context.setShadow(offset: .zero, blur: 12 * scale, color: color(glowBlue))
    context.setStrokeColor(color(coreLight))
    context.setLineWidth(2.2)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(chevron); context.strokePath()
    context.addPath(chevron); context.strokePath()
    context.restoreGState()
}

/// Finder draws the labels of a window with a background picture in black, in the light and in the
/// dark appearance, and has no setting for it. So the white labels are part of the picture. The labels
/// of Finder stay, black on the dark place of each icon, where they do not show.
func drawLabels(_ context: CGContext) {
    let graphics = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    for (centre, name) in [(Layout.app, "Interspace"), (Layout.applications, "Applications")] {
        let text = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.93, green: 0.95, blue: 1, alpha: 0.95),
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: centre.x - size.width / 2, y: centre.y + Layout.labelOffset - size.height / 2))
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// The icons and labels, about as Finder draws them. Only for the preview.
func drawFinderItems(_ context: CGContext, labelColor: NSColor, appIcon: NSImage) {
    let graphics = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let items: [(CGPoint, NSImage, String)] = [
        (Layout.app, appIcon, "Interspace"),
        (Layout.applications, NSWorkspace.shared.icon(forFile: "/Applications"), "Applications"),
    ]
    for (centre, icon, name) in items {
        let half = Layout.iconSize / 2
        let frame = CGRect(x: centre.x - half, y: centre.y - half, width: Layout.iconSize, height: Layout.iconSize)
        icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let text = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: labelColor,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: centre.x - size.width / 2, y: centre.y + Layout.finderLabelOffset - size.height / 2))
    }
    NSGraphicsContext.restoreGraphicsState()
}

func write(_ context: CGContext, to path: String, scale: CGFloat) {
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    // The size in points, so the 2x picture is known as 144 dpi.
    rep.size = NSSize(width: Layout.width, height: Layout.height)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let work = NSTemporaryDirectory() + "interspace-dmg-background"
try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)

for scale in [CGFloat(1), 2] {
    let context = makeContext(scale: scale)
    drawBackground(context, scale: scale)
    write(context, to: "\(work)/\(Int(scale))x.png", scale: scale)
}

let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", "\(work)/1x.png", "\(work)/2x.png", "-out", "\(root)/Resources/dmg-background.tiff"]
try! tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { exit(1) }
print("Wrote Resources/dmg-background.tiff")

if CommandLine.arguments.contains("--preview") {
    let appIcon = NSImage(contentsOfFile: "\(root)/Resources/AppIcon.icns")!
    try? FileManager.default.createDirectory(atPath: "\(root)/build", withIntermediateDirectories: true)
    let context = makeContext(scale: 2)
    drawBackground(context, scale: 2)
    drawFinderItems(context, labelColor: .black, appIcon: appIcon)
    write(context, to: "\(root)/build/dmg-preview.png", scale: 2)
    print("Wrote build/dmg-preview.png")
}
