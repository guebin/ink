import Cocoa

// Ink app icon — a Bob-Ross-flavored sunset landscape (style homage only:
// happy little trees, a snow-capped peak, a warm sky — no likeness or marks).
// Renders 1024×1024 PNG to argv[1].

let S: CGFloat = 1024

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S),
                      xRadius: S * 0.2235, yRadius: S * 0.2235)

/// A fir tree: stacked triangles + trunk.
func tree(at x: CGFloat, base y: CGFloat, height h: CGFloat, width w: CGFloat,
          dark: NSColor, light: NSColor) {
    rgb(0.28, 0.20, 0.14).setFill()
    NSBezierPath(rect: NSRect(x: x - w * 0.045, y: y, width: w * 0.09, height: h * 0.16)).fill()
    let tiers = 4
    for i in 0..<tiers {
        let f = CGFloat(i) / CGFloat(tiers)
        let tierBase = y + h * (0.12 + f * 0.62)
        let tierW = w * (1.0 - f * 0.62)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x - tierW / 2, y: tierBase))
        p.line(to: NSPoint(x: x + tierW / 2, y: tierBase))
        p.line(to: NSPoint(x: x, y: tierBase + h * 0.38))
        p.close()
        (i % 2 == 0 ? dark : light).setFill()
        p.fill()
    }
}

/// Snow-capped mountain.
func mountain(peak: NSPoint, halfWidth: CGFloat, baseY: CGFloat,
              rock: NSColor, snow: NSColor) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: peak.x - halfWidth, y: baseY))
    p.line(to: peak)
    p.line(to: NSPoint(x: peak.x + halfWidth, y: baseY))
    p.close()
    rock.setFill()
    p.fill()
    let capH = (peak.y - baseY) * 0.36
    let capW = halfWidth * 0.36
    let c = NSBezierPath()
    c.move(to: NSPoint(x: peak.x - capW, y: peak.y - capH))
    c.line(to: NSPoint(x: peak.x - capW * 0.35, y: peak.y - capH * 0.55))
    c.line(to: NSPoint(x: peak.x - capW * 0.1, y: peak.y - capH * 0.85))
    c.line(to: peak)
    c.line(to: NSPoint(x: peak.x + capW * 0.15, y: peak.y - capH * 0.7))
    c.line(to: NSPoint(x: peak.x + capW * 0.5, y: peak.y - capH * 0.4))
    c.line(to: NSPoint(x: peak.x + capW, y: peak.y - capH))
    c.close()
    snow.setFill()
    c.fill()
}

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// Warm sunset sky: amber → coral → dusk violet.
NSGradient(colors: [rgb(1.00, 0.70, 0.42), rgb(0.93, 0.40, 0.34), rgb(0.42, 0.30, 0.50)])!
    .draw(in: bg, angle: -90)

NSGraphicsContext.current?.saveGraphicsState()
bg.addClip()

// Sun.
NSColor(white: 1, alpha: 0.85).setFill()
let sr = S * 0.11
NSBezierPath(ovalIn: NSRect(x: S * 0.66 - sr, y: S * 0.63 - sr,
                            width: sr * 2, height: sr * 2)).fill()

// Peak.
mountain(peak: NSPoint(x: S * 0.38, y: S * 0.60), halfWidth: S * 0.34, baseY: S * 0.26,
         rock: rgb(0.32, 0.24, 0.38), snow: rgb(0.96, 0.90, 0.92))

// Dark ground + happy little trees.
rgb(0.14, 0.16, 0.22).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: S, height: S * 0.26)).fill()
for (x, h) in [(0.14, 0.30), (0.30, 0.22), (0.50, 0.34), (0.70, 0.24), (0.87, 0.30)] {
    tree(at: S * CGFloat(x), base: S * 0.20, height: S * CGFloat(h), width: S * 0.17,
         dark: rgb(0.10, 0.13, 0.18), light: rgb(0.14, 0.18, 0.24))
}

NSGraphicsContext.current?.restoreGraphicsState()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/ink-icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
