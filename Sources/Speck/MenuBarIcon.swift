import AppKit

/// Speck's menu bar mark: a dot with two sound waves. Rendered as a template image, so macOS
/// draws it white on dark/tinted menu bars and black on light ones.
enum MenuBarIcon {
    static let playing = make(alpha: 1)
    static let idle = make(alpha: 0.55)

    private static func make(alpha: CGFloat) -> NSImage {
        let size: CGFloat = 16
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let color = NSColor.black.withAlphaComponent(alpha).cgColor
            let dot = CGPoint(x: 5.2, y: size / 2)

            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: dot.x - 2.4, y: dot.y - 2.4, width: 4.8, height: 4.8))

            ctx.setStrokeColor(color)
            ctx.setLineCap(.round)
            ctx.setLineWidth(1.7)
            for radius: CGFloat in [5.0, 8.2] {
                ctx.addArc(center: dot, radius: radius, startAngle: -.pi / 3.6, endAngle: .pi / 3.6, clockwise: false)
                ctx.strokePath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
