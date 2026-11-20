import AppKit

// Draws the Notch Shelf app icon at 1024×1024 on the macOS icon grid.
// Usage: swift scripts/make-icon.swift icon-1024.png, then resize into NotchShelf/Assets.xcassets/AppIcon.appiconset.
let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Flip so y grows downward, which matches the shelf drawing code.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// Squircle body: 824pt on a 1024 canvas, as in Apple's macOS template.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Soft drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(color(0x1A1D24))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Background: a cool dusk gradient, like a desktop behind the menu bar.
let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                    colors: [color(0x5B6CF0), color(0x7B4FD8), color(0x2A1F5C)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 180, y: 100), end: CGPoint(x: 840, y: 924), options: [])

// Menu bar band across the top.
let barHeight: CGFloat = 92
ctx.setFillColor(color(0xFFFFFF, 0.20))
ctx.fill(CGRect(x: 100, y: 100, width: 824, height: barHeight))

// Menu bar items left and right of the notch.
ctx.setFillColor(color(0xFFFFFF, 0.75))
for x in [168.0, 230.0] {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 132, width: 40, height: 28), cornerWidth: 9, cornerHeight: 9, transform: nil))
}
for x in [756.0, 818.0] {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 132, width: 40, height: 28), cornerWidth: 9, cornerHeight: 9, transform: nil))
}
ctx.fillPath()

// The shelf: black, attached to the top edge, opening out of the notch.
let shelf = CGMutablePath()
let left: CGFloat = 232, right: CGFloat = 792, top: CGFloat = 100, bottom: CGFloat = 600, r: CGFloat = 92
shelf.move(to: CGPoint(x: left - 34, y: top))
shelf.addLine(to: CGPoint(x: right + 34, y: top))
// Small outward shoulders, like the notch meeting the menu bar.
shelf.addQuadCurve(to: CGPoint(x: right, y: top + 34), control: CGPoint(x: right, y: top))
shelf.addLine(to: CGPoint(x: right, y: bottom - r))
shelf.addQuadCurve(to: CGPoint(x: right - r, y: bottom), control: CGPoint(x: right, y: bottom))
shelf.addLine(to: CGPoint(x: left + r, y: bottom))
shelf.addQuadCurve(to: CGPoint(x: left, y: bottom - r), control: CGPoint(x: left, y: bottom))
shelf.addLine(to: CGPoint(x: left, y: top + 34))
shelf.addQuadCurve(to: CGPoint(x: left - 34, y: top), control: CGPoint(x: left, y: top))
shelf.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 40, color: color(0x000000, 0.45))
ctx.addPath(shelf)
ctx.setFillColor(color(0x050507))
ctx.fillPath()
ctx.restoreGState()

// Three tray icons inside the shelf.
let tiles: [(CGFloat, UInt32, UInt32)] = [(300, 0xFFB347, 0xFF7A3D), (448, 0x5EE7C9, 0x22B5A8), (596, 0xFF7EB6, 0xE2468C)]
for (x, a, b) in tiles {
    let rect = CGRect(x: x, y: 250, width: 128, height: 128)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(a), color(b)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    ctx.restoreGState()
}

// Playback bar along the bottom of the shelf.
ctx.setFillColor(color(0xFFFFFF, 0.22))
ctx.addPath(CGPath(roundedRect: CGRect(x: 300, y: 470, width: 424, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil))
ctx.fillPath()
ctx.setFillColor(color(0xFFFFFF, 0.92))
ctx.addPath(CGPath(roundedRect: CGRect(x: 300, y: 470, width: 250, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil))
ctx.fillPath()


// Pointer heading for the notch: the gesture that opens the shelf.
let cursor = CGMutablePath()
let tip = CGPoint(x: 600, y: 664)
let pts: [(CGFloat, CGFloat)] = [(0,0),(0,170),(42,130),(72,198),(104,184),(74,118),(130,118)]
cursor.move(to: tip)
for (dx, dy) in pts.dropFirst() { cursor.addLine(to: CGPoint(x: tip.x + dx, y: tip.y + dy)) }
cursor.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: color(0x000000, 0.4))
ctx.addPath(cursor)
ctx.setFillColor(color(0x111114))
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(cursor)
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(12)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.addPath(cursor)
ctx.setFillColor(color(0x111114))
ctx.fillPath()

ctx.restoreGState()

// Hairline edge highlight on the body.
ctx.addPath(squircle)
ctx.setStrokeColor(color(0xFFFFFF, 0.14))
ctx.setLineWidth(3)
ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
