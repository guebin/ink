import Cocoa

/// The current drawing (foreground) color. Click to open the system color
/// panel for a custom color.
final class ColorChip: NSView {
    var color: NSColor = .black { didSet { needsDisplay = true } }
    var onChange: ((NSColor) -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        NSColor.white.setFill()
        rect.fill()
        color.setFill()
        rect.fill()
        NSColor.darkGray.setStroke()
        let p = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        p.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let panel = NSColorPanel.shared
        panel.color = color
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(panelChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func panelChanged(_ sender: NSColorPanel) {
        color = sender.color
        onChange?(color)
    }
}
