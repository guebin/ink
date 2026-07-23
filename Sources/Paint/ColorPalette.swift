import Cocoa

/// A compact grid of preset colors (like MS Paint). Click a swatch to set the
/// drawing color without opening the system color panel.
final class ColorPalette: NSView {
    var onPick: ((NSColor) -> Void)?

    private let cols = 14
    private let rows = 2
    private let cell: CGFloat = 15

    private let colors: [NSColor] = [
        // row 1 — saturated / dark
        rgb(0, 0, 0),       rgb(127, 127, 127), rgb(136, 0, 21),   rgb(237, 28, 36),
        rgb(255, 127, 39),  rgb(255, 242, 0),   rgb(34, 177, 76),  rgb(0, 128, 128),
        rgb(0, 162, 232),   rgb(0, 0, 255),     rgb(63, 72, 204),  rgb(163, 73, 164),
        rgb(255, 0, 144),   rgb(112, 60, 20),
        // row 2 — light / pastel
        rgb(255, 255, 255), rgb(195, 195, 195), rgb(185, 122, 87), rgb(255, 174, 201),
        rgb(255, 201, 14),  rgb(239, 228, 176), rgb(181, 230, 29), rgb(153, 217, 234),
        rgb(112, 176, 240), rgb(125, 125, 255), rgb(200, 191, 231),rgb(214, 159, 222),
        rgb(255, 199, 220), rgb(206, 174, 140),
    ]

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(cols) * cell, height: CGFloat(rows) * cell)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, c) in colors.enumerated() {
            let col = i % cols, row = i / cols
            let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                              width: cell - 1, height: cell - 1)
            c.setFill()
            rect.fill()
            NSColor.gray.withAlphaComponent(0.6).setStroke()
            let p = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let col = Int(p.x / cell), row = Int(p.y / cell)
        guard col >= 0, col < cols, row >= 0, row < rows else { return }
        let idx = row * cols + col
        guard idx >= 0, idx < colors.count else { return }
        onPick?(colors[idx])
    }
}
