// Renders Speck's app icon: a green dot (the "speck") with sound waves on a dark macOS squircle.
// Usage: swift Icon/make-icon.swift Icon/AppIcon-1024.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: 824pt squircle inset 100pt, with a soft drop shadow
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x121212)); ctx.fillPath()
ctx.restoreGState()

// Background: subtle top-lit gradient
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x2A2A2A), rgb(0x0E0E0E)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// The "speck": a small green dot with sound waves spreading to the right
let dot = CGPoint(x: 392, y: 512)
let r: CGFloat = 72
let green = rgb(0x1ED760)

let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x1ED760, 0.30), rgb(0x1ED760, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 380, options: [])

let disc = CGGradient(colorsSpace: cs, colors: [rgb(0x3FEA80), rgb(0x1DB954)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
ctx.drawLinearGradient(disc, start: CGPoint(x: dot.x, y: dot.y + r), end: CGPoint(x: dot.x, y: dot.y - r), options: [])
ctx.restoreGState()

// Concentric waves, fading as they travel outward
ctx.setLineCap(.round)
for (radius, width, alpha) in [(CGFloat(150), CGFloat(46), CGFloat(1.0)), (230, 42, 0.72), (310, 38, 0.45)] {
    ctx.addArc(center: dot, radius: radius, startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
    ctx.setStrokeColor(green.copy(alpha: alpha)!)
    ctx.setLineWidth(width)
    ctx.strokePath()
}
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
