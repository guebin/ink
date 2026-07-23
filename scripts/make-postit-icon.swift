import Cocoa

// Renders a 1024×1024 post-it (sticky note) icon PNG with a transparent
// background. Output path is argv[1].

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// Center origin, slight tilt for a hand-stuck look.
ctx.translateBy(x: S / 2, y: S / 2)
ctx.rotate(by: -4 * .pi / 180)

let half: CGFloat = 360       // half side of the note
let fold: CGFloat = 150       // size of the peeled bottom-right corner

// Note body (square with the bottom-right corner cut for the fold).
let body = CGMutablePath()
body.move(to: CGPoint(x: -half, y: half))          // top-left
body.addLine(to: CGPoint(x: half, y: half))        // top-right
body.addLine(to: CGPoint(x: half, y: -half + fold))// right edge down to fold
body.addLine(to: CGPoint(x: half - fold, y: -half))// across the fold
body.addLine(to: CGPoint(x: -half, y: -half))      // bottom-left
body.closeSubpath()

// Drop shadow + yellow gradient fill.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 46,
              color: NSColor.black.withAlphaComponent(0.30).cgColor)
ctx.addPath(body)
ctx.clip()
let yellow = CGGradient(colorsSpace: cs, colors: [
    NSColor(srgbRed: 1.00, green: 0.92, blue: 0.45, alpha: 1).cgColor,   // top
    NSColor(srgbRed: 1.00, green: 0.84, blue: 0.27, alpha: 1).cgColor,   // bottom
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(yellow, start: CGPoint(x: 0, y: half),
                       end: CGPoint(x: 0, y: -half), options: [])
ctx.restoreGState()

// The peeled corner: a triangle that looks turned up.
let curl = CGMutablePath()
curl.move(to: CGPoint(x: half, y: -half + fold))
curl.addLine(to: CGPoint(x: half - fold, y: -half))
curl.addLine(to: CGPoint(x: half - fold, y: -half + fold))
curl.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: -6, height: 8), blur: 16,
              color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.addPath(curl); ctx.clip()
let curlGrad = CGGradient(colorsSpace: cs, colors: [
    NSColor(srgbRed: 1.00, green: 0.97, blue: 0.78, alpha: 1).cgColor,
    NSColor(srgbRed: 0.96, green: 0.80, blue: 0.30, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(curlGrad,
                       start: CGPoint(x: half - fold, y: -half),
                       end: CGPoint(x: half, y: -half + fold), options: [])
ctx.restoreGState()

// A few ruled "note" lines.
ctx.saveGState()
ctx.setStrokeColor(NSColor(srgbRed: 0.80, green: 0.66, blue: 0.18, alpha: 0.55).cgColor)
ctx.setLineWidth(16)
ctx.setLineCap(.round)
let lineX0 = -half + 70
for (i, y) in [half - 150, half - 300, half - 450].enumerated() {
    let x1 = (i == 2) ? half - fold - 30 : half - 70   // last line stops before the fold
    ctx.move(to: CGPoint(x: lineX0, y: y))
    ctx.addLine(to: CGPoint(x: x1, y: y))
}
ctx.strokePath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
