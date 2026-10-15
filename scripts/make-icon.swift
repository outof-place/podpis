// Draws the app icon at 1024 px: usage `swift scripts/make-icon.swift out.png`.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Body: the macOS icon grid leaves 100 px around an 824 px rounded square.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = color(0x000000, 0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color(0x1c2366).setFill()
bodyPath.fill()
ctx.restoreGState()

bodyPath.addClip()
NSGradient(colors: [color(0x3a49ad), color(0x232d80), color(0x161c55)], atLocations: [0, 0.55, 1],
           colorSpace: .sRGB)!.draw(in: body, angle: -90)
NSGradient(colors: [color(0xffffff, 0.18), color(0xffffff, 0)])!.draw(
    in: CGRect(x: body.minX, y: body.midY + 120, width: body.width, height: body.height / 2 - 120), angle: -90)

// Paper, tilted a little.
ctx.saveGState()
ctx.translateBy(x: 480, y: 545)
ctx.rotate(by: 7 * .pi / 180)
let paper = CGRect(x: -215, y: -285, width: 430, height: 570)
let paperShadow = NSShadow()
paperShadow.shadowColor = color(0x000000, 0.35)
paperShadow.shadowBlurRadius = 30
paperShadow.shadowOffset = NSSize(width: 0, height: -14)
ctx.saveGState()
paperShadow.set()
color(0xfbfbfd).setFill()
NSBezierPath(roundedRect: paper, xRadius: 34, yRadius: 34).fill()
ctx.restoreGState()
// Text lines.
color(0x1c2366, 0.16).setFill()
for (i, w) in [300.0, 340, 320, 250].enumerated() {
    NSBezierPath(roundedRect: CGRect(x: -165, y: 190 - Double(i) * 52, width: w, height: 20), xRadius: 10, yRadius: 10).fill()
}
// Signature line.
color(0x1c2366, 0.3).setFill()
NSBezierPath(roundedRect: CGRect(x: -165, y: -170, width: 330, height: 6), xRadius: 3, yRadius: 3).fill()
// The ink signature, a loose cursive stroke crossing the line.
let sig = NSBezierPath()
sig.move(to: CGPoint(x: -170, y: -150))
sig.curve(to: CGPoint(x: -95, y: -40), controlPoint1: CGPoint(x: -150, y: -60), controlPoint2: CGPoint(x: -120, y: -20))
sig.curve(to: CGPoint(x: -80, y: -175), controlPoint1: CGPoint(x: -60, y: -70), controlPoint2: CGPoint(x: -110, y: -190))
sig.curve(to: CGPoint(x: 10, y: -95), controlPoint1: CGPoint(x: -50, y: -160), controlPoint2: CGPoint(x: -20, y: -80))
sig.curve(to: CGPoint(x: 60, y: -150), controlPoint1: CGPoint(x: 35, y: -110), controlPoint2: CGPoint(x: 25, y: -170))
sig.curve(to: CGPoint(x: 120, y: -90), controlPoint1: CGPoint(x: 90, y: -130), controlPoint2: CGPoint(x: 95, y: -70))
sig.curve(to: CGPoint(x: 185, y: -125), controlPoint1: CGPoint(x: 140, y: -105), controlPoint2: CGPoint(x: 160, y: -140))
sig.lineWidth = 17
sig.lineCapStyle = .round
sig.lineJoinStyle = .round
color(0x26307e).setStroke()
sig.stroke()
ctx.restoreGState()

// Seal with a check mark, over the lower right corner of the paper.
let c = CGPoint(x: 690, y: 300)
let r: CGFloat = 128
ctx.saveGState()
let sealShadow = NSShadow()
sealShadow.shadowColor = color(0x000000, 0.35)
sealShadow.shadowBlurRadius = 24
sealShadow.shadowOffset = NSSize(width: 0, height: -10)
sealShadow.set()
color(0xffffff).setFill()
NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
ctx.restoreGState()
let inner = NSBezierPath(ovalIn: CGRect(x: c.x - r + 16, y: c.y - r + 16, width: 2 * r - 32, height: 2 * r - 32))
ctx.saveGState()
inner.addClip()
NSGradient(colors: [color(0x43d17a), color(0x1f9d50)])!.draw(in: inner.bounds, angle: -90)
ctx.restoreGState()
let check = NSBezierPath()
check.move(to: CGPoint(x: c.x - 52, y: c.y + 2))
check.line(to: CGPoint(x: c.x - 14, y: c.y - 38))
check.line(to: CGPoint(x: c.x + 58, y: c.y + 44))
check.lineWidth = 30
check.lineCapStyle = .round
check.lineJoinStyle = .round
color(0xffffff).setStroke()
check.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
