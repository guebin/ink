import Cocoa

// Renders a 1024×1024 app icon PNG: a colored rounded square with a white
// canvas and a rainbow brush stroke. Output path is argv[1].

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)

// Rounded-square background with a diagonal gradient.
let corner = S * 0.2235
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                    cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath); ctx.clip()
let bgGrad = CGGradient(colorsSpace: cs, colors: [
    NSColor(srgbRed: 0.33, green: 0.49, blue: 0.96, alpha: 1).cgColor,
    NSColor(srgbRed: 0.12, green: 0.20, blue: 0.62, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
ctx.restoreGState()

// White canvas card with a soft shadow.
let canvasRect = CGRect(x: S * 0.21, y: S * 0.21, width: S * 0.58, height: S * 0.58)
let canvasPath = CGPath(roundedRect: canvasRect, cornerWidth: S * 0.045,
                        cornerHeight: S * 0.045, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
              color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(canvasPath); ctx.fillPath()
ctx.restoreGState()

// Rainbow brush stroke (an S-curve) clipped to the canvas.
ctx.saveGState()
ctx.addPath(canvasPath); ctx.clip()
let stroke = CGMutablePath()
stroke.move(to: CGPoint(x: canvasRect.minX + S * 0.07, y: canvasRect.minY + S * 0.12))
stroke.addCurve(to: CGPoint(x: canvasRect.maxX - S * 0.07, y: canvasRect.maxY - S * 0.12),
                control1: CGPoint(x: canvasRect.midX + S * 0.02, y: canvasRect.minY - S * 0.02),
                control2: CGPoint(x: canvasRect.midX - S * 0.02, y: canvasRect.maxY + S * 0.02))
ctx.addPath(stroke)
ctx.setLineWidth(S * 0.11)
ctx.setLineCap(.round)
ctx.replacePathWithStrokedPath()
ctx.clip()
let rainbow = CGGradient(colorsSpace: cs, colors: [
    NSColor.systemRed.cgColor, NSColor.systemOrange.cgColor, NSColor.systemYellow.cgColor,
    NSColor.systemGreen.cgColor, NSColor.systemBlue.cgColor, NSColor.systemPurple.cgColor,
] as CFArray, locations: [0, 0.2, 0.4, 0.6, 0.8, 1])!
ctx.drawLinearGradient(rainbow,
                       start: CGPoint(x: canvasRect.minX, y: canvasRect.minY),
                       end: CGPoint(x: canvasRect.maxX, y: canvasRect.maxY), options: [])
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
