import Cocoa

// Center-crops an input image to a square and renders it as a 1024×1024
// rounded-square app icon (transparent corners), with an optional margin so
// the tile sits slightly inset like standard macOS icons.
// usage: make-image-icon <input> <output.png> [marginFraction]   e.g. 0.08

guard CommandLine.arguments.count >= 3,
      let src = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: make-image-icon <input> <output.png>\n".data(using: .utf8)!)
    exit(1)
}

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// Square center-crop of the source.
let w = CGFloat(srcCG.width), h = CGFloat(srcCG.height)
let side = min(w, h)
let cropRect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
let square = srcCG.cropping(to: cropRect) ?? srcCG

// Inset the rounded tile so it matches standard macOS icons (≈10% margin).
let margin = (CommandLine.arguments.count > 3 ? CGFloat(Double(CommandLine.arguments[3]) ?? 0.10) : 0.10) * S
let tile = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = tile.width * 0.2235

// Soft drop shadow under the tile, like other app icons.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
              color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.fillPath()
ctx.restoreGState()

// Rounded-square clip, then draw the image to fill the inset tile.
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.draw(square, in: tile)

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("wrote \(CommandLine.arguments[2])")
