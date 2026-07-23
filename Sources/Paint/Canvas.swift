import Cocoa

/// Raster canvas backed by a CGBitmapContext (RGBA, premultipliedLast, sRGB).
/// All drawing is pixel-based — no stroke smoothing / handwriting correction.
final class Canvas {
    private(set) var width: Int
    private(set) var height: Int
    private(set) var ctx: CGContext

    private var undoStack: [CGImage] = []
    private var redoStack: [CGImage] = []
    private let maxUndo = 40

    init(width: Int, height: Int, fill: NSColor = .white) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.ctx = Canvas.makeContext(self.width, self.height)
        ctx.setFillColor(fill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: self.width, height: self.height))
    }

    static func makeContext(_ w: Int, _ h: Int) -> CGContext {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: max(1, w), height: max(1, h),
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        return ctx
    }

    var cgImage: CGImage? { ctx.makeImage() }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    // MARK: - Undo / Redo

    func snapshot() {
        if let img = ctx.makeImage() {
            undoStack.append(img)
            if undoStack.count > maxUndo { undoStack.removeFirst() }
            redoStack.removeAll()
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let img = undoStack.popLast() else { return }
        if let cur = ctx.makeImage() { redoStack.append(cur) }
        resetTo(img)
    }

    func redo() {
        guard let img = redoStack.popLast() else { return }
        if let cur = ctx.makeImage() { undoStack.append(cur) }
        resetTo(img)
    }

    /// Replace the pixels with `img` without touching the undo stacks.
    /// Snapshots can predate an auto-expansion, so this follows the image's size.
    func resetTo(_ img: CGImage) {
        if img.width != width || img.height != height {
            width = img.width
            height = img.height
            ctx = Canvas.makeContext(width, height)
        }
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.draw(img, in: bounds)
        ctx.restoreGState()
    }

    // MARK: - Freeform auto-expansion

    /// Grow the bitmap so `rect` (canvas coords) fits, padding new space with
    /// `background`. Existing content shifts by the returned (dx, dy); the
    /// caller must shift any coordinates it is holding. No snapshot is taken —
    /// expansion is part of whatever stroke triggered it. Returns nil when the
    /// rect already fits.
    func expandIfNeeded(toInclude rect: CGRect, background: NSColor,
                        chunk: CGFloat = 512) -> (dx: CGFloat, dy: CGFloat)? {
        let needL = max(0, -rect.minX)
        let needB = max(0, -rect.minY)
        let needR = max(0, rect.maxX - CGFloat(width))
        let needT = max(0, rect.maxY - CGFloat(height))
        guard needL > 0 || needB > 0 || needR > 0 || needT > 0 else { return nil }
        // Grow in chunks so a stroke crawling along an edge doesn't realloc
        // the bitmap on every mouse event.
        func grow(_ n: CGFloat) -> Int { n > 0 ? Int(max(n, chunk).rounded(.up)) : 0 }
        let l = grow(needL), b = grow(needB), r = grow(needR), t = grow(needT)
        guard let old = ctx.makeImage() else { return nil }
        let newW = width + l + r
        let newH = height + b + t
        let newCtx = Canvas.makeContext(newW, newH)
        newCtx.setFillColor(background.cgColor)
        newCtx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        newCtx.draw(old, in: CGRect(x: l, y: b, width: width, height: height))
        ctx = newCtx
        width = newW
        height = newH
        return (CGFloat(l), CGFloat(b))
    }

    /// Pad `img` onto a `width`×`height` background at `offset` — keeps a
    /// shape-preview base image in sync when the canvas expands mid-drag.
    static func pad(_ img: CGImage, width: Int, height: Int,
                    offset: (x: CGFloat, y: CGFloat), background: NSColor) -> CGImage? {
        let ctx = makeContext(width, height)
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(img, in: CGRect(x: offset.x, y: offset.y,
                                 width: CGFloat(img.width), height: CGFloat(img.height)))
        return ctx.makeImage()
    }

    // MARK: - Replace whole image (open / new / resize)

    func replace(with img: CGImage) {
        snapshot()
        let w = img.width, h = img.height
        if w != width || h != height {
            width = w; height = h
            ctx = Canvas.makeContext(w, h)
        }
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.draw(img, in: bounds)
        ctx.restoreGState()
    }

    // MARK: - Brush / pencil strokes

    func drawSegment(from a: CGPoint, to b: CGPoint, color: CGColor,
                     size: CGFloat, hard: Bool) {
        ctx.saveGState()
        ctx.setShouldAntialias(!hard)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(size)
        ctx.setLineCap(hard ? .square : .round)
        ctx.setLineJoin(.round)
        if a == b {
            // single dot
            if hard {
                let s = max(1, size)
                ctx.fill(CGRect(x: (a.x - s / 2).rounded(.down),
                                y: (a.y - s / 2).rounded(.down),
                                width: s, height: s))
            } else {
                ctx.fillEllipse(in: CGRect(x: a.x - size / 2, y: a.y - size / 2,
                                           width: size, height: size))
            }
        } else {
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Shapes (drawn against a saved base image for live preview)

    func drawShape(_ tool: Tool, from a: CGPoint, to b: CGPoint,
                   stroke: CGColor, fill: CGColor, size: CGFloat,
                   filled: Bool, base: CGImage?) {
        // reset to base (live preview), then draw shape; base is nil for the
        // final draw after an auto-expansion, where the canvas is already clean
        if let base {
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.draw(base, in: bounds)
            ctx.restoreGState()
        }

        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        ctx.saveGState()
        ctx.setShouldAntialias(tool != .line ? true : true)
        ctx.setStrokeColor(stroke)
        ctx.setFillColor(fill)
        ctx.setLineWidth(size)
        ctx.setLineJoin(.miter)
        ctx.setLineCap(.butt)
        switch tool {
        case .line:
            ctx.setLineCap(.round)
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        case .rect:
            if filled { ctx.fill(rect) }
            ctx.stroke(rect, width: size)
        case .ellipse:
            if filled { ctx.fillEllipse(in: rect) }
            ctx.strokeEllipse(in: rect)
        default: break
        }
        ctx.restoreGState()
    }

    // MARK: - Text

    /// Caller is responsible for snapshot() (it must happen before any
    /// auto-expansion so undo restores the pre-expansion size).
    func drawText(_ string: String, at point: CGPoint, color: NSColor, fontSize: CGFloat) {
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color
        ]
        (string as NSString).draw(at: point, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Paste / composite image at point

    func composite(_ img: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.setBlendMode(.normal)
        ctx.draw(img, in: rect)
        ctx.restoreGState()
    }

    func clearRect(_ rect: CGRect, color: CGColor) {
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.setFillColor(color)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    func crop(_ rect: CGRect) -> CGImage? {
        let r = rect.integral.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        guard let full = ctx.makeImage() else { return nil }
        // Our rects use a bottom-left origin, but CGImage.cropping uses a
        // top-left origin — flip Y so we crop the region the user selected.
        let flipped = CGRect(x: r.minX, y: CGFloat(height) - r.maxY,
                             width: r.width, height: r.height)
        return full.cropping(to: flipped)
    }

    // MARK: - Flood fill (scanline, exact-match by default)

    func floodFill(at p: CGPoint, with color: NSColor, tolerance: Int = 0) {
        guard let data = ctx.data else { return }
        let x0 = Int(p.x), y0 = Int(p.y)
        guard x0 >= 0, x0 < width, y0 >= 0, y0 < height else { return }
        snapshot()
        let bpr = ctx.bytesPerRow
        let buf = data.assumingMemoryBound(to: UInt8.self)

        func idx(_ x: Int, _ y: Int) -> Int { (height - 1 - y) * bpr + x * 4 }

        let start = idx(x0, y0)
        let tr = buf[start], tg = buf[start + 1], tb = buf[start + 2], ta = buf[start + 3]

        // target color (premultiplied bytes)
        let fill = color.usingColorSpace(.sRGB) ?? color
        let fa = UInt8((fill.alphaComponent * 255).rounded())
        let fr = UInt8((fill.redComponent * fill.alphaComponent * 255).rounded())
        let fg = UInt8((fill.greenComponent * fill.alphaComponent * 255).rounded())
        let fb = UInt8((fill.blueComponent * fill.alphaComponent * 255).rounded())

        if fr == tr, fg == tg, fb == tb, fa == ta { return } // already that color

        func matches(_ i: Int) -> Bool {
            let dr = abs(Int(buf[i]) - Int(tr))
            let dg = abs(Int(buf[i + 1]) - Int(tg))
            let db = abs(Int(buf[i + 2]) - Int(tb))
            let da = abs(Int(buf[i + 3]) - Int(ta))
            return dr <= tolerance && dg <= tolerance && db <= tolerance && da <= tolerance
        }
        func setPixel(_ i: Int) {
            buf[i] = fr; buf[i + 1] = fg; buf[i + 2] = fb; buf[i + 3] = fa
        }

        var stack: [(Int, Int)] = [(x0, y0)]
        while let (sx, sy) = stack.popLast() {
            var x = sx
            while x >= 0 && matches(idx(x, sy)) { x -= 1 }
            x += 1
            var spanUp = false, spanDown = false
            while x < width && matches(idx(x, sy)) {
                setPixel(idx(x, sy))
                if sy + 1 < height {
                    let up = matches(idx(x, sy + 1))
                    if up && !spanUp { stack.append((x, sy + 1)); spanUp = true }
                    else if !up { spanUp = false }
                }
                if sy - 1 >= 0 {
                    let dn = matches(idx(x, sy - 1))
                    if dn && !spanDown { stack.append((x, sy - 1)); spanDown = true }
                    else if !dn { spanDown = false }
                }
                x += 1
            }
        }
    }

    // MARK: - Save / Load

    func pngData() -> Data? {
        guard let img = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .png, properties: [:])
    }

    func jpegData(quality: CGFloat = 0.9) -> Data? {
        guard let img = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
