import AppKit

// Draws the Notch Shelf app icon at 1024×1024 on the macOS icon grid: a black
// menu bar and the notch with its camera, a usage ring on the left and play on the right.
// Usage: swift scripts/make-icon.swift icon-1024.png, then resize into
// NotchShelf/Assets.xcassets/AppIcon.appiconset.
let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Flip so y grows downward. Shadow offsets ignore this, so they use negative y.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// Squircle body: 824pt on a 1024 canvas, as in Apple's macOS template.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(color(0x2A1F5C))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Background: the screen around the notch.
let bg = CGGradient(colorsSpace: srgb, colors: [color(0x6A7BFF), color(0x7B4FD8), color(0x2A1F5C)] as CFArray,
                    locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 824, y: 924), options: [])

// A black menu bar across the top, and the notch with wings hanging from it:
// small outward shoulders where it meets the bar, rounded lower corners.
// The bar ends where the body's rounded top corners end.
let barBottom: CGFloat = body.minY + 186
let left: CGFloat = 222, right: CGFloat = 802, top: CGFloat = barBottom, bottom: CGFloat = 480
let shoulder: CGFloat = 40, corner: CGFloat = 120
let notch = CGMutablePath()
notch.addRect(CGRect(x: 0, y: 0, width: size, height: barBottom))
notch.move(to: CGPoint(x: left - shoulder, y: top))
notch.addLine(to: CGPoint(x: right + shoulder, y: top))
notch.addQuadCurve(to: CGPoint(x: right, y: top + shoulder), control: CGPoint(x: right, y: top))
notch.addLine(to: CGPoint(x: right, y: bottom - corner))
notch.addQuadCurve(to: CGPoint(x: right - corner, y: bottom), control: CGPoint(x: right, y: bottom))
notch.addLine(to: CGPoint(x: left + corner, y: bottom))
notch.addQuadCurve(to: CGPoint(x: left, y: bottom - corner), control: CGPoint(x: left, y: bottom))
notch.addLine(to: CGPoint(x: left, y: top + shoulder))
notch.addQuadCurve(to: CGPoint(x: left - shoulder, y: top), control: CGPoint(x: left, y: top))
notch.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 48, color: color(0x000000, 0.45))
ctx.addPath(notch)
ctx.setFillColor(color(0x050507))
ctx.fillPath()
ctx.restoreGState()

// The camera sits where the menu bar meets the notch. The wings sit lower,
// centered in the part of the notch below the bar, near its sides.
let midY = barBottom
let wingY = (barBottom + bottom) / 2 - 6
let ink = color(0xE8E8EE)

// Left wing: usage ring. Light arc is the remaining share, dark track the used share.
let ring = CGPoint(x: 336, y: wingY)
let radius: CGFloat = 70, line: CGFloat = 24
ctx.setLineWidth(line)
ctx.setLineCap(.round)
ctx.setStrokeColor(color(0xFFFFFF, 0.18))
ctx.addArc(center: ring, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
ctx.strokePath()
ctx.setStrokeColor(ink)
// Starts at 12 o'clock and runs clockwise (in flipped space) for 70%.
ctx.addArc(center: ring, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * 0.7, clockwise: false)
ctx.strokePath()

// Right wing: play triangle with softened corners.
let play = CGMutablePath()
let cx: CGFloat = 694, h: CGFloat = 140
let p1 = CGPoint(x: cx - h * 0.42, y: wingY - h / 2)
let p2 = CGPoint(x: cx + h * 0.5, y: wingY)
let p3 = CGPoint(x: cx - h * 0.42, y: wingY + h / 2)
play.move(to: CGPoint(x: (p1.x + p3.x) / 2, y: (p1.y + p3.y) / 2))
play.addArc(tangent1End: p1, tangent2End: p2, radius: 16)
play.addArc(tangent1End: p2, tangent2End: p3, radius: 16)
play.addArc(tangent1End: p3, tangent2End: p1, radius: 16)
play.closeSubpath()
ctx.addPath(play)
ctx.setFillColor(ink)
ctx.fillPath()

// Camera in the middle of the notch: housing, dark lens and a small glint.
let camera = CGPoint(x: 512, y: midY)
for (r, hex) in [(CGFloat(30), UInt32(0x1E1F27)), (17, 0x08080C)] {
    ctx.addEllipse(in: CGRect(x: camera.x - r, y: camera.y - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(color(hex))
    ctx.fillPath()
}
ctx.addEllipse(in: CGRect(x: camera.x - 9, y: camera.y - 9, width: 8, height: 8))
ctx.setFillColor(color(0x5A6FB8, 0.85))
ctx.fillPath()

ctx.restoreGState()

// Hairline edge highlight on the body.
ctx.addPath(squircle)
ctx.setStrokeColor(color(0xFFFFFF, 0.14))
ctx.setLineWidth(3)
ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
