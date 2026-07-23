import Cocoa

/// A floating image that hasn't been committed to the canvas yet
/// (used for paste and for moving a selection). Drawn on top of the bitmap.
private struct Floating {
    var image: CGImage
    var origin: CGPoint   // bottom-left in canvas coords
    var size: CGSize
    var rect: CGRect { CGRect(origin: origin, size: size) }
}

final class CanvasView: NSView {
    let canvas: Canvas

    /// Freeform-style scroll room around the canvas. The document view is the
    /// canvas plus this margin on every side; drawing in the margin auto-grows
    /// the canvas. All interaction state is kept in canvas coordinates
    /// (view coords minus the margin).
    let canvasMargin: CGFloat = 1024

    /// Where the canvas sits inside the (larger) document view.
    var canvasFrame: CGRect {
        CGRect(x: canvasMargin, y: canvasMargin,
               width: CGFloat(canvas.width), height: CGFloat(canvas.height))
    }

    // Tool state (set from the toolbar)
    var tool: Tool = .pen {
        didSet {
            if oldValue != tool {
                commitFloating(); cancelMarquee()
                window?.invalidateCursorRects(for: self)
                if let h = hoverPoint { updateHover(h) }
            }
        }
    }
    var primaryColor: NSColor = .black
    /// The eraser and selection-clear paint with the canvas background (white).
    let eraserColor: NSColor = .white
    var brushSize: CGFloat = 3 {
        didSet { if let h = hoverPoint { updateHover(h) } }
    }
    var shapeFilled: Bool = false

    // Brush-size cursor preview (pen / eraser)
    private var hoverPoint: CGPoint?
    private var lastPreviewRect: CGRect?
    private var trackingArea: NSTrackingArea?
    private var showsBrushPreview: Bool { tool == .eraser || tool == .pen }

    // Callbacks to the UI
    var onCanvasChanged: (() -> Void)?

    // Drag state
    private var lastPoint: CGPoint?
    private var shapeStart: CGPoint?
    private var shapeBase: CGImage?

    // Selection marquee
    private var marquee: CGRect?
    private var marqueeStart: CGPoint?

    // Floating overlay (paste / move)
    private var floating: Floating?
    private var floatDragOffset: CGSize?
    private var liftedFromRect: CGRect?   // where a moved selection was lifted from

    // Resizing the floating overlay by its handles
    private var resizeHandle: Handle?
    private var resizeStartRect: CGRect = .zero

    // Inline text editing
    private var textField: NSTextField?
    private var textOrigin: CGPoint?

    init(canvas: Canvas) {
        self.canvas = canvas
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: CGFloat(canvas.width) + 2048,
                                 height: CGFloat(canvas.height) + 2048))
        wantsLayer = true
        resizeToCanvas()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }   // bottom-left origin, matches CG context
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func resizeToCanvas() {
        setFrameSize(NSSize(width: CGFloat(canvas.width) + canvasMargin * 2,
                            height: CGFloat(canvas.height) + canvasMargin * 2))
        needsDisplay = true
    }

    // MARK: - Freeform auto-expansion

    /// Grow the canvas so `rect` (canvas coords) fits, shifting every piece of
    /// interaction state and the scroll position so nothing visibly jumps.
    /// Returns the shift applied to existing canvas coordinates.
    @discardableResult
    func expandCanvasIfNeeded(toInclude rect: CGRect) -> (dx: CGFloat, dy: CGFloat) {
        guard let (dx, dy) = canvas.expandIfNeeded(toInclude: rect,
                                                   background: eraserColor) else {
            return (0, 0)
        }
        shiftInteractionState(dx: dx, dy: dy)
        if let clip = enclosingScrollView?.contentView {
            let o = clip.bounds.origin
            resizeToCanvas()
            clip.scroll(to: NSPoint(x: o.x + dx, y: o.y + dy))
            enclosingScrollView?.reflectScrolledClipView(clip)
        } else {
            resizeToCanvas()
        }
        return (dx, dy)
    }

    /// Canvas grew by (dx, dy) at the left/bottom — shift everything we track
    /// in canvas coordinates.
    private func shiftInteractionState(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        func s(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        lastPoint = lastPoint.map(s)
        shapeStart = shapeStart.map(s)
        marqueeStart = marqueeStart.map(s)
        marquee = marquee?.offsetBy(dx: dx, dy: dy)
        liftedFromRect = liftedFromRect?.offsetBy(dx: dx, dy: dy)
        if var f = floating { f.origin = s(f.origin); floating = f }
        resizeStartRect = resizeStartRect.offsetBy(dx: dx, dy: dy)
        textOrigin = textOrigin.map(s)
        hoverPoint = hoverPoint.map(s)
        lastPreviewRect = nil
        if let tf = textField {
            tf.setFrameOrigin(NSPoint(x: tf.frame.origin.x + dx,
                                      y: tf.frame.origin.y + dy))
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        // Freeform-style gray desk around the canvas.
        NSColor(white: 0.82, alpha: 1).setFill()
        dirtyRect.fill()

        // Everything below is in canvas coordinates.
        cg.saveGState()
        cg.translateBy(x: canvasMargin, y: canvasMargin)

        NSColor.white.setFill()
        canvas.bounds.fill()
        if let img = canvas.cgImage {
            cg.draw(img, in: canvas.bounds)
        }
        cg.setStrokeColor(NSColor(white: 0.6, alpha: 1).cgColor)
        cg.setLineWidth(1)
        cg.stroke(canvas.bounds.insetBy(dx: -0.5, dy: -0.5))

        if let f = floating {
            cg.draw(f.image, in: f.rect)
            drawDashedBox(f.rect, cg: cg)
            drawHandles(f.rect, cg: cg)
        }
        if let m = marquee {
            drawDashedBox(m, cg: cg)
        }
        if showsBrushPreview, let h = hoverPoint, floating == nil {
            drawBrushPreview(at: h, cg: cg)
        }
        cg.restoreGState()
    }

    // MARK: - Brush-size preview cursor

    private func brushPreviewRect(at p: CGPoint) -> CGRect {
        let s = max(1, brushSize)
        return CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
    }

    private func drawBrushPreview(at p: CGPoint, cg: CGContext) {
        let r = brushPreviewRect(at: p).insetBy(dx: 0.5, dy: 0.5)
        let round = (tool == .pen)   // pen is round, eraser square
        cg.saveGState()
        cg.setLineWidth(1)
        cg.setStrokeColor(NSColor.white.cgColor)
        if round { cg.strokeEllipse(in: r) } else { cg.stroke(r) }
        cg.setLineDash(phase: 0, lengths: [3, 3])
        cg.setStrokeColor(NSColor.black.cgColor)
        if round { cg.strokeEllipse(in: r) } else { cg.stroke(r) }
        cg.restoreGState()
    }

    private func updateHover(_ p: CGPoint) {
        hoverPoint = p
        guard showsBrushPreview else {
            if let old = lastPreviewRect {
                setNeedsDisplay(old.offsetBy(dx: canvasMargin, dy: canvasMargin))
                lastPreviewRect = nil
            }
            return
        }
        let newR = brushPreviewRect(at: p).insetBy(dx: -2, dy: -2)
        if let old = lastPreviewRect {
            setNeedsDisplay(old.offsetBy(dx: canvasMargin, dy: canvasMargin))
        }
        setNeedsDisplay(newR.offsetBy(dx: canvasMargin, dy: canvasMargin))
        lastPreviewRect = newR
    }

    private func drawDashedBox(_ rect: CGRect, cg: CGContext) {
        cg.saveGState()
        cg.setLineWidth(1)
        cg.setStrokeColor(NSColor.black.cgColor)
        cg.setLineDash(phase: 0, lengths: [4, 4])
        cg.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        cg.setStrokeColor(NSColor.white.cgColor)
        cg.setLineDash(phase: 4, lengths: [4, 4])
        cg.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        cg.restoreGState()
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x - canvasMargin, y: p.y - canvasMargin)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        let p = point(event)
        updateHover(p)

        // Floating overlay: a resize handle -> resize; inside -> move; outside -> commit.
        if let f = floating {
            if let h = handleHit(at: p, in: f.rect) {
                resizeHandle = h
                resizeStartRect = f.rect
                return
            }
            if f.rect.contains(p) {
                floatDragOffset = CGSize(width: p.x - f.origin.x, height: p.y - f.origin.y)
                return
            }
            commitFloating()
        }

        let color = primaryColor

        switch tool {
        case .pen, .eraser:
            canvas.snapshot()   // before expansion, so undo restores the old size
            let pad = strokeSize / 2 + 2
            let (dx, dy) = expandCanvasIfNeeded(
                toInclude: CGRect(x: p.x - pad, y: p.y - pad, width: pad * 2, height: pad * 2))
            let q = CGPoint(x: p.x + dx, y: p.y + dy)
            lastPoint = q
            let c = (tool == .eraser ? eraserColor : color)
            canvas.drawSegment(from: q, to: q, color: c.cgColor,
                               size: strokeSize, hard: false)
            changed()

        case .line, .rect, .ellipse:
            canvas.snapshot()
            shapeStart = p
            shapeBase = canvas.cgImage

        case .fill:
            canvas.floodFill(at: p, with: color)
            changed()

        case .select:
            if let m = marquee, m.contains(p) {
                // grab existing selection -> lift into a movable floating image
                liftSelection()
                if let f = floating {
                    floatDragOffset = CGSize(width: p.x - f.origin.x, height: p.y - f.origin.y)
                }
            } else {
                marquee = nil
                marqueeStart = p
                marquee = CGRect(origin: p, size: .zero)
                needsDisplay = true
            }

        case .text:
            beginText(at: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // Follow the drag past the window edge so the canvas can keep growing.
        autoscroll(with: event)
        let p = clamp(point(event))
        updateHover(p)

        if let h = resizeHandle, var f = floating {
            let r = resizedRect(handle: h, start: resizeStartRect, to: p,
                                keepAspect: event.modifierFlags.contains(.shift))
            f.origin = r.origin
            f.size = r.size
            floating = f
            needsDisplay = true
            return
        }

        if let off = floatDragOffset, var f = floating {
            f.origin = CGPoint(x: p.x - off.width, y: p.y - off.height)
            floating = f
            needsDisplay = true
            return
        }

        switch tool {
        case .pen, .eraser:
            guard lastPoint != nil else { return }
            let pad = strokeSize / 2 + 2
            let (dx, dy) = expandCanvasIfNeeded(
                toInclude: CGRect(x: p.x - pad, y: p.y - pad, width: pad * 2, height: pad * 2))
            let q = CGPoint(x: p.x + dx, y: p.y + dy)
            let c = (tool == .eraser ? eraserColor : primaryColor)
            // re-read lastPoint: expansion shifts it along with the content
            canvas.drawSegment(from: lastPoint!, to: q, color: c.cgColor,
                               size: strokeSize, hard: false)
            lastPoint = q
            changed()

        case .line, .rect, .ellipse:
            guard shapeStart != nil, shapeBase != nil else { return }
            // Expand live while dragging; pad the preview base to the new size
            // so resetting to it doesn't stretch.
            let pad = max(brushSize, 2)
            let rect = CGRect(x: min(shapeStart!.x, p.x), y: min(shapeStart!.y, p.y),
                              width: abs(p.x - shapeStart!.x), height: abs(p.y - shapeStart!.y))
                .insetBy(dx: -pad, dy: -pad)
            let oldW = canvas.width, oldH = canvas.height
            let (dx, dy) = expandCanvasIfNeeded(toInclude: rect)
            if canvas.width != oldW || canvas.height != oldH, let b = shapeBase {
                shapeBase = Canvas.pad(b, width: canvas.width, height: canvas.height,
                                       offset: (dx, dy), background: eraserColor) ?? b
            }
            let q = CGPoint(x: p.x + dx, y: p.y + dy)
            let c = primaryColor
            canvas.drawShape(tool, from: shapeStart!, to: q, stroke: c.cgColor,
                             fill: c.cgColor, size: brushSize,
                             filled: shapeFilled, base: shapeBase)
            needsDisplay = true

        case .select:
            guard let s = marqueeStart else { return }
            marquee = CGRect(x: min(s.x, p.x), y: min(s.y, p.y),
                             width: abs(p.x - s.x), height: abs(p.y - s.y))
            needsDisplay = true

        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if resizeHandle != nil { resizeHandle = nil; return }
        if floatDragOffset != nil { floatDragOffset = nil; return }

        switch tool {
        case .pen, .eraser:
            lastPoint = nil
            changed()
        case .line, .rect, .ellipse:
            // Redraw the final shape after auto-expanding: the live preview is
            // clipped at the old canvas edge, so wipe it, grow, then draw clean.
            if let base = shapeBase, let start = shapeStart {
                let p = clamp(point(event))
                canvas.resetTo(base)
                let pad = max(brushSize, 2)
                let raw = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                 width: abs(p.x - start.x), height: abs(p.y - start.y))
                    .insetBy(dx: -pad, dy: -pad)
                let (dx, dy) = expandCanvasIfNeeded(toInclude: raw)
                let c = primaryColor
                canvas.drawShape(tool,
                                 from: CGPoint(x: start.x + dx, y: start.y + dy),
                                 to: CGPoint(x: p.x + dx, y: p.y + dy),
                                 stroke: c.cgColor, fill: c.cgColor, size: brushSize,
                                 filled: shapeFilled, base: nil)
            }
            shapeStart = nil; shapeBase = nil
            changed()
        case .select:
            marqueeStart = nil
            if let m = marquee, m.width < 2 || m.height < 2 { marquee = nil; needsDisplay = true }
        default: break
        }
    }

    private var strokeSize: CGFloat { max(1, brushSize) }

    private func clamp(_ p: CGPoint) -> CGPoint {
        // The whole margin is drawable (the canvas grows to meet the stroke).
        CGPoint(x: min(max(-canvasMargin, p.x), CGFloat(canvas.width) + canvasMargin),
                y: min(max(-canvasMargin, p.y), CGFloat(canvas.height) + canvasMargin))
    }

    private func changed() {
        needsDisplay = true
        onCanvasChanged?()
    }

    // MARK: - Floating overlay resize handles

    /// The eight resize handles around a floating overlay. Corners are listed
    /// first so they win hit-testing over the edge handles they sit beside.
    private enum Handle {
        case bottomLeft, bottomRight, topLeft, topRight, left, right, bottom, top
    }
    private static let handleOrder: [Handle] =
        [.bottomLeft, .bottomRight, .topLeft, .topRight, .left, .right, .bottom, .top]

    private func handleCenter(_ h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .bottomLeft:  return CGPoint(x: r.minX, y: r.minY)
        case .bottom:      return CGPoint(x: r.midX, y: r.minY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.minY)
        case .left:        return CGPoint(x: r.minX, y: r.midY)
        case .right:       return CGPoint(x: r.maxX, y: r.midY)
        case .topLeft:     return CGPoint(x: r.minX, y: r.maxY)
        case .top:         return CGPoint(x: r.midX, y: r.maxY)
        case .topRight:    return CGPoint(x: r.maxX, y: r.maxY)
        }
    }
    /// Horizontal edge the handle drags: -1 = left (minX), +1 = right (maxX), 0 = none.
    private func handleEdgeX(_ h: Handle) -> Int {
        switch h {
        case .bottomLeft, .left, .topLeft:    return -1
        case .bottomRight, .right, .topRight: return  1
        default:                              return  0
        }
    }
    /// Vertical edge the handle drags: -1 = bottom (minY), +1 = top (maxY), 0 = none.
    private func handleEdgeY(_ h: Handle) -> Int {
        switch h {
        case .bottomLeft, .bottom, .bottomRight: return -1
        case .topLeft, .top, .topRight:          return  1
        default:                                 return  0
        }
    }

    /// Hit-test the handles (a bit larger than they're drawn, for easy grabbing).
    private func handleHit(at p: CGPoint, in r: CGRect) -> Handle? {
        let radius: CGFloat = 8
        for h in Self.handleOrder {
            let c = handleCenter(h, in: r)
            if abs(p.x - c.x) <= radius && abs(p.y - c.y) <= radius { return h }
        }
        return nil
    }

    private func drawHandles(_ r: CGRect, cg: CGContext) {
        let s: CGFloat = 7
        cg.saveGState()
        cg.setLineWidth(1)
        for h in Self.handleOrder {
            let c = handleCenter(h, in: r)
            let box = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
            cg.setFillColor(NSColor.white.cgColor)
            cg.fill(box)
            cg.setStrokeColor(NSColor.black.cgColor)
            cg.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        }
        cg.restoreGState()
    }

    /// New rect for a handle drag. The opposite edge/corner stays anchored;
    /// `keepAspect` (hold Shift) locks a corner drag to the image's proportions.
    private func resizedRect(handle h: Handle, start: CGRect, to p: CGPoint,
                             keepAspect: Bool) -> CGRect {
        let ex = handleEdgeX(h), ey = handleEdgeY(h)
        var minX = start.minX, maxX = start.maxX
        var minY = start.minY, maxY = start.maxY

        if keepAspect, ex != 0, ey != 0, start.height > 0 {
            // Corner drag with proportions locked — grow from the fixed corner.
            let aspect = start.width / start.height
            let anchorX = ex < 0 ? start.maxX : start.minX
            let anchorY = ey < 0 ? start.maxY : start.minY
            var w = abs(p.x - anchorX)
            var hgt = abs(p.y - anchorY)
            if w / max(hgt, 0.001) > aspect { hgt = w / aspect } else { w = hgt * aspect }
            if ex < 0 { minX = anchorX - w } else { maxX = anchorX + w }
            if ey < 0 { minY = anchorY - hgt } else { maxY = anchorY + hgt }
        } else {
            if ex < 0 { minX = p.x } else if ex > 0 { maxX = p.x }
            if ey < 0 { minY = p.y } else if ey > 0 { maxY = p.y }
        }

        // Enforce a minimum size, keeping the non-dragged edge anchored.
        let minSize: CGFloat = 8
        if maxX - minX < minSize { if ex < 0 { minX = maxX - minSize } else { maxX = minX + minSize } }
        if maxY - minY < minSize { if ey < 0 { minY = maxY - minSize } else { maxY = minY + minSize } }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func resizeCursor(for h: Handle) -> NSCursor {
        switch h {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default:            return .crosshair   // no public diagonal-resize cursor
        }
    }

    /// Keep a sensible cursor whenever a floating overlay is present.
    private func updateCursor(at p: CGPoint) {
        if let f = floating {
            if let h = handleHit(at: p, in: f.rect) { resizeCursor(for: h).set(); return }
            if f.rect.contains(p) { NSCursor.openHand.set(); return }
        }
        (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
    }

    // MARK: - Floating overlay / selection lifecycle

    func commitFloating() {
        guard let pending = floating else { return }
        canvas.snapshot()
        // Grow the canvas if the overlay hangs past an edge (Freeform-style);
        // expansion shifts `floating`, so re-read it afterwards.
        expandCanvasIfNeeded(toInclude: pending.rect)
        guard let f = floating else { return }
        canvas.composite(f.image, in: f.rect)
        floating = nil
        liftedFromRect = nil
        changed()
    }

    private func cancelMarquee() {
        marquee = nil
        needsDisplay = true
    }

    /// Lift the current marquee into a floating, movable selection.
    private func liftSelection() {
        guard let m = marquee, let cropped = canvas.crop(m) else { return }
        canvas.snapshot()
        canvas.clearRect(m.integral, color: eraserColor.cgColor) // fill hole with bg
        floating = Floating(image: cropped, origin: m.integral.origin,
                            size: CGSize(width: cropped.width, height: cropped.height))
        marquee = nil
        changed()
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        let img: CGImage?
        if let f = floating { img = f.image }
        else if let m = marquee { img = canvas.crop(m) }
        else { img = canvas.cgImage }
        guard let cg = img else { NSSound.beep(); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = rep.representation(using: .png, properties: [:]) {
            pb.setData(data, forType: .png)
        }
        let nsimg = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        pb.writeObjects([nsimg])
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        if let m = marquee {
            canvas.snapshot()
            canvas.clearRect(m.integral, color: eraserColor.cgColor)
            marquee = nil
            changed()
        } else if floating != nil {
            floating = nil
            changed()
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let cg = CanvasView.imageFromPasteboard() else {
            NSSound.beep()
            return
        }
        commitFloating()
        tool = .select
        // place near top-left of the visible area (canvas coords = view - margin)
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let ox = visible.minX - canvasMargin + 8
        let oy = visible.maxY - canvasMargin - h - 8
        floating = Floating(image: cg,
                            origin: CGPoint(x: max(0, ox), y: max(0, oy)),
                            size: CGSize(width: w, height: h))
        window?.makeFirstResponder(self)
        changed()
    }

    /// Robust image extraction from the pasteboard — handles screenshots
    /// (TIFF/PNG), copied files, and PDF, in priority order.
    static func imageFromPasteboard() -> CGImage? {
        let pb = NSPasteboard.general

        // 1) Direct bitmap data types
        for type in [NSPasteboard.PasteboardType.png,
                     NSPasteboard.PasteboardType.tiff] {
            if let data = pb.data(forType: type),
               let rep = NSBitmapImageRep(data: data),
               let cg = rep.cgImage {
                return cg
            }
        }
        // 2) NSImage objects (covers most screenshot/clipboard cases)
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = imgs.first {
            var rect = CGRect(origin: .zero, size: img.size)
            if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return cg
            }
        }
        // 3) File URLs pointing at an image
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL],
           let url = urls.first,
           let img = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: img.size)
            return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return nil
    }

    override func selectAll(_ sender: Any?) {
        tool = .select
        marquee = canvas.bounds
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / Enter -> commit floating
            if floating != nil { commitFloating() }
            else { super.keyDown(with: event) }
        case 53: // Escape -> cancel floating / marquee
            if floating != nil { floating = nil; changed() }
            else if marquee != nil { cancelMarquee() }
            else { super.keyDown(with: event) }
        case 51, 117: // Delete / Forward delete
            if floating != nil { floating = nil; changed() }
            else if let m = marquee {
                canvas.snapshot()
                canvas.clearRect(m.integral, color: eraserColor.cgColor)
                marquee = nil; changed()
            } else { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Hover tracking (brush-size preview)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        updateHover(p)
        updateCursor(at: p)
    }

    override func mouseExited(with event: NSEvent) {
        if let old = lastPreviewRect {
            setNeedsDisplay(old.offsetBy(dx: canvasMargin, dy: canvasMargin))
            lastPreviewRect = nil
        }
        hoverPoint = nil
    }

    // MARK: - Inline text

    private func beginText(at p: CGPoint) {
        commitText()
        let fontSize = max(12, brushSize * 6)
        // subview frames are in view coords, one margin over from canvas coords
        let tf = NSTextField(frame: NSRect(x: p.x + canvasMargin, y: p.y + canvasMargin,
                                           width: 200, height: fontSize + 8))
        tf.font = NSFont.systemFont(ofSize: fontSize)
        tf.textColor = .black   // text defaults to black regardless of pen color
        tf.backgroundColor = NSColor.white.withAlphaComponent(0.6)
        tf.isBordered = true
        tf.focusRingType = .none
        tf.target = self
        tf.action = #selector(textCommitted(_:))
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textField = tf
        textOrigin = p
    }

    @objc private func textCommitted(_ sender: NSTextField) {
        commitText()
    }

    private func commitText() {
        guard let tf = textField, let origin = textOrigin else { return }
        let s = tf.stringValue
        let fontSize = tf.font?.pointSize ?? 16
        let color = tf.textColor ?? primaryColor
        tf.removeFromSuperview()
        textField = nil
        textOrigin = nil
        guard !s.isEmpty else { return }
        canvas.snapshot()   // before expansion, so undo restores the old size
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize)]
        let textSize = (s as NSString).size(withAttributes: attrs)
        let (dx, dy) = expandCanvasIfNeeded(
            toInclude: CGRect(origin: origin, size: textSize).insetBy(dx: -4, dy: -4))
        canvas.drawText(s, at: CGPoint(x: origin.x + dx, y: origin.y + dy),
                        color: color, fontSize: fontSize)
        changed()
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        // Always keep a visible cursor; the size outline is drawn on top.
        let cursor: NSCursor = (tool == .text) ? .iBeam : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }
}
