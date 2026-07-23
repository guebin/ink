import Cocoa

// Renders a 1024×1024 "동글동글" round bubble icon PNG (transparent bg).
// Output path is argv[1].

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high
ctx.translateBy(x: S / 2, y: S / 2)

func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGRect {
    CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
}

// Fill a circle with a vertical gradient (and optional drop shadow).
func fillCircle(_ rect: CGRect, top: NSColor, bottom: NSColor, shadow: Bool) {
    ctx.saveGState()
    if shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
    }
    ctx.addEllipse(in: rect); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [top.cgColor, bottom.cgColor] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()
}

// Two small accent bubbles behind, then the big main bubble — gives a round,
// "동글동글" clustered look.
fillCircle(circle(215, 225, 120),
           top: NSColor(srgbRed: 0.62, green: 0.78, blue: 1.00, alpha: 1),
           bottom: NSColor(srgbRed: 0.40, green: 0.58, blue: 0.98, alpha: 1), shadow: true)
fillCircle(circle(-255, -250, 95),
           top: NSColor(srgbRed: 0.78, green: 0.66, blue: 1.00, alpha: 1),
           bottom: NSColor(srgbRed: 0.55, green: 0.42, blue: 0.97, alpha: 1), shadow: true)

let main = circle(-30, 10, 360)
fillCircle(main,
           top: NSColor(srgbRed: 0.56, green: 0.46, blue: 0.98, alpha: 1),
           bottom: NSColor(srgbRed: 0.36, green: 0.34, blue: 0.92, alpha: 1), shadow: true)

// Glossy highlight near the top of the main bubble.
ctx.saveGState()
ctx.addEllipse(in: main); ctx.clip()
ctx.setFillColor(NSColor.white.withAlphaComponent(0.30).cgColor)
ctx.fillEllipse(in: CGRect(x: main.minX + 70, y: main.midY + 60,
                           width: main.width - 250, height: main.height * 0.42))
// small specular dot
ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
ctx.fillEllipse(in: circle(main.midX - 150, main.midY + 150, 38))
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
