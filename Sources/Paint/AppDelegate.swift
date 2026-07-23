import Cocoa
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var canvasView: CanvasView!
    var scrollView: NSScrollView!

    // Toolbar controls
    private var toolControl: NSSegmentedControl!
    private var colorChip: ColorChip!
    private var palette: ColorPalette!
    private var sizeSlider: NSSlider!
    private var sizeLabel: NSTextField!
    private var fillCheck: NSButton!
    private var zoomLabel: NSTextField!

    private var documentURL: URL?
    private var dirty = false

    /// Each tool remembers its own brush size (eraser is independent from the pen).
    private var toolSizes: [Tool: CGFloat] = [
        .pen: 4, .eraser: 20,
        .line: 2, .rect: 2, .ellipse: 2,
        .fill: 1, .text: 3, .select: 1,
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        // Default canvas is Full HD (1920×1080); drawing past an edge grows it
        // automatically (Freeform-style), so starting small costs nothing.
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let toolbarH: CGFloat = 44
        let winW = min(1920, (vis.width * 0.95).rounded())
        let winH = min(1080 + toolbarH, (vis.height * 0.95).rounded())

        let canvas = Canvas(width: 1920, height: 1080)
        canvasView = CanvasView(canvas: canvas)

        let toolbar = buildToolbar()

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = NSColor(white: 0.82, alpha: 1)
        scrollView.documentView = canvasView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.allowsMagnification = true            // trackpad pinch-to-zoom
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 32
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyEnded(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

        let container = NSView()
        container.addSubview(toolbar)
        container.addSubview(scrollView)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Paint"
        window.contentView = container
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvasView)

        canvasView.onCanvasChanged = { [weak self] in self?.dirty = true }

        syncToolbarToView()
        NSApp.activate(ignoringOtherApps: true)
        centerCanvas()
    }

    /// Scroll so the canvas is centered in the viewport (when it's larger than
    /// the visible area). Default NSScrollView focus is the bottom-left corner.
    func centerCanvas() {
        scrollView.layoutSubtreeIfNeeded()
        guard let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let docSize = doc.frame.size
        let visSize = clip.bounds.size
        let x = max(0, (docSize.width  - visSize.width)  / 2)
        let y = max(0, (docSize.height - visSize.height) / 2)
        clip.scroll(to: NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Toolbar

    private func buildToolbar() -> NSView {
        let bar = NSView()

        toolControl = NSSegmentedControl(labels: Tool.allCases.map { $0.label },
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(toolChanged(_:)))
        for (i, t) in Tool.allCases.enumerated() {
            toolControl.setToolTip(t.tooltip, forSegment: i)
            toolControl.setWidth(34, forSegment: i)
        }
        toolControl.selectedSegment = 0

        colorChip = ColorChip()
        colorChip.color = .black
        colorChip.toolTip = "Drawing color — click for a custom color"
        colorChip.onChange = { [weak self] c in
            self?.canvasView.primaryColor = c
        }

        palette = ColorPalette()
        palette.onPick = { [weak self] c in
            self?.colorChip.color = c
            self?.canvasView.primaryColor = c
        }

        sizeSlider = NSSlider(value: 3, minValue: 1, maxValue: 64,
                              target: self, action: #selector(sizeChanged(_:)))
        sizeSlider.numberOfTickMarks = 0
        sizeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true

        sizeLabel = NSTextField(labelWithString: "3 px")
        sizeLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        fillCheck = NSButton(checkboxWithTitle: "Fill", target: self, action: #selector(fillToggled(_:)))

        // Compact zoom controls; "Zoom to Fit" and Actual Size live in the View menu.
        let zoomOutBtn = NSButton(title: "−", target: self, action: #selector(zoomOut(_:)))
        let zoomInBtn  = NSButton(title: "+", target: self, action: #selector(zoomIn(_:)))
        for b in [zoomOutBtn, zoomInBtn] {
            b.bezelStyle = .rounded
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        zoomOutBtn.toolTip = "Zoom out (⌘−)"
        zoomInBtn.toolTip  = "Zoom in (⌘+)"
        zoomLabel = NSTextField(labelWithString: "100%")
        zoomLabel.alignment = .center
        zoomLabel.toolTip = "Zoom — ⌘0 = 100%, ⌘9 = fit, or pinch on the trackpad"
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let stack = NSStackView(views: [
            toolControl,
            spacer(8),
            colorChip, palette,
            spacer(8),
            NSTextField(labelWithString: "Size"), sizeSlider, sizeLabel,
            fillCheck,
            spacer(8),
            zoomOutBtn, zoomLabel, zoomInBtn,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            colorChip.widthAnchor.constraint(equalToConstant: 32),
            colorChip.heightAnchor.constraint(equalToConstant: 32),
        ])
        return bar
    }

    private func spacer(_ w: CGFloat) -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        return v
    }

    private func syncToolbarToView() {
        canvasView.tool = Tool.allCases[toolControl.selectedSegment]
        canvasView.primaryColor = colorChip.color
        canvasView.shapeFilled = fillCheck.state == .on
        applySizeForCurrentTool()
    }

    /// Push the stored size for the active tool into the slider + canvas.
    private func applySizeForCurrentTool() {
        let v = toolSizes[canvasView.tool] ?? 3
        sizeSlider.doubleValue = Double(v)
        canvasView.brushSize = v
        sizeLabel.stringValue = "\(Int(v)) px"
    }

    @objc private func toolChanged(_ s: NSSegmentedControl) {
        canvasView.tool = Tool.allCases[s.selectedSegment]
        applySizeForCurrentTool()
    }
    @objc private func sizeChanged(_ s: NSSlider) {
        let v = CGFloat(Int(s.doubleValue.rounded()))
        toolSizes[canvasView.tool] = v       // store per-tool, not shared
        canvasView.brushSize = v
        sizeLabel.stringValue = "\(Int(v)) px"
    }
    @objc private func fillToggled(_ b: NSButton) { canvasView.shapeFilled = b.state == .on }

    // MARK: - Zoom

    private func applyZoom(_ mag: CGFloat) {
        let m = min(max(mag, scrollView.minMagnification), scrollView.maxMagnification)
        let vis = scrollView.documentVisibleRect
        scrollView.setMagnification(m, centeredAt: NSPoint(x: vis.midX, y: vis.midY))
        updateZoomLabel()
    }
    private func updateZoomLabel() {
        zoomLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%"
    }
    @objc private func zoomIn(_ sender: Any?)     { applyZoom(scrollView.magnification * 1.25) }
    @objc private func zoomOut(_ sender: Any?)    { applyZoom(scrollView.magnification / 1.25) }
    @objc private func zoomActual(_ sender: Any?) { applyZoom(1) }
    @objc private func zoomToFit(_ sender: Any?) {
        scrollView.magnify(toFit: canvasView.canvasFrame)
        updateZoomLabel()
    }
    @objc private func liveMagnifyEnded(_ n: Notification) { updateZoomLabel() }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Paint", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Paint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New", action: #selector(newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]

        // Edit
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        // Explicit target = self so ⌘Z/⌘⇧Z reach our own undo stack instead of
        // being swallowed (and disabled) by NSWindow's built-in NSUndoManager.
        let undoItem = editMenu.addItem(withTitle: "Undo", action: #selector(undo(_:)), keyEquivalent: "z")
        undoItem.target = self
        let redo = editMenu.addItem(withTitle: "Redo", action: #selector(redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.target = self
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")

        // Image
        let imgItem = NSMenuItem(); mainMenu.addItem(imgItem)
        let imgMenu = NSMenu(title: "Image"); imgItem.submenu = imgMenu
        imgMenu.addItem(withTitle: "Canvas Size…", action: #selector(canvasSize(_:)), keyEquivalent: "")
        imgMenu.addItem(withTitle: "Clear Canvas", action: #selector(clearCanvas(_:)), keyEquivalent: "k")

        // View
        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View"); viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size (100%)", action: #selector(zoomActual(_:)), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom to Fit", action: #selector(zoomToFit(_:)), keyEquivalent: "9")

        NSApp.mainMenu = mainMenu
    }

    // MARK: - File actions

    /// ⌘N: ask about unsaved changes once, then open a fresh canvas right away
    /// (no size dialog — the canvas auto-grows, so the default size is enough).
    @objc private func newDocument(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        let blank = Canvas(width: 1920, height: 1080)
        if let img = blank.cgImage { canvasView.canvas.replace(with: img) }
        canvasView.resizeToCanvas()
        centerCanvas()
        documentURL = nil
        window.title = "Paint"
        dirty = false
    }

    @objc private func openDocument(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .image]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            guard let img = NSImage(contentsOf: url),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                NSSound.beep(); return
            }
            self.canvasView.canvas.replace(with: cg)
            self.canvasView.resizeToCanvas()
            self.centerCanvas()
            self.documentURL = url
            self.window.title = url.lastPathComponent
            self.dirty = false
        }
    }

    @objc private func saveDocument(_ sender: Any?) {
        if let url = documentURL { write(to: url) }
        else { saveDocumentAs(sender) }
    }

    @objc private func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = (documentURL?.lastPathComponent ?? "Untitled.png")
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            self.write(to: url)
            self.documentURL = url
            self.window.title = url.lastPathComponent
        }
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        let data = isJPEG ? canvasView.canvas.jpegData() : canvasView.canvas.pngData()
        guard let data else { NSSound.beep(); return false }
        do { try data.write(to: url); dirty = false; return true }
        catch { NSSound.beep(); return false }
    }

    // MARK: - Unsaved-changes guard

    /// Ask to save when the canvas has unsaved changes. Returns true if it's OK
    /// to proceed (nothing to lose, saved, or "Don't Save"); false to abort.
    private func confirmDiscardIfDirty() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save your changes?"
        alert.informativeText = "Your current drawing will be lost if you don't save it."
        alert.addButton(withTitle: "Save")         // right / default
        alert.addButton(withTitle: "Cancel")       // middle
        alert.addButton(withTitle: "Don't Save")   // left
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return saveSynchronously()  // Save
        case .alertSecondButtonReturn: return false                // Cancel
        default:                       return true                 // Don't Save
        }
    }

    /// Synchronous save, prompting for a location when the file is untitled.
    /// Returns true only if the file was actually written.
    private func saveSynchronously() -> Bool {
        if let url = documentURL { return write(to: url) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "Untitled.png"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard write(to: url) else { return false }
        documentURL = url
        window.title = url.lastPathComponent
        return true
    }

    // MARK: - Edit actions

    // resizeToCanvas: undo/redo can cross an auto-expansion, changing the size
    @objc private func undo(_ sender: Any?) { canvasView.canvas.undo(); canvasView.resizeToCanvas() }
    @objc private func redo(_ sender: Any?) { canvasView.canvas.redo(); canvasView.resizeToCanvas() }

    /// Grey out Undo/Redo when there's nothing to undo/redo.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return canvasView?.canvas.canUndo ?? false
        case #selector(redo(_:)): return canvasView?.canvas.canRedo ?? false
        default: return true
        }
    }

    // MARK: - Image actions

    @objc private func canvasSize(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Canvas Size"
        alert.informativeText = "Existing content stays anchored to the top-left."
        let acc = SizeAccessory(defaultW: canvasView.canvas.width, defaultH: canvasView.canvas.height)
        alert.accessoryView = acc
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let (cw, ch) = acc.chosenSize
            let nw = cw > 0 ? cw : canvasView.canvas.width
            let nh = ch > 0 ? ch : canvasView.canvas.height
            // resize keeping existing content anchored bottom-left
            let new = Canvas(width: nw, height: nh)
            if let old = canvasView.canvas.cgImage {
                new.composite(old, in: CGRect(x: 0, y: CGFloat(nh - canvasView.canvas.height),
                                              width: CGFloat(old.width), height: CGFloat(old.height)))
            }
            if let img = new.cgImage { canvasView.canvas.replace(with: img) }
            canvasView.resizeToCanvas()
            centerCanvas()
        }
    }

    @objc private func clearCanvas(_ sender: Any?) {
        canvasView.canvas.snapshot()
        canvasView.canvas.clearRect(canvasView.canvas.bounds, color: canvasView.eraserColor.cgColor)
        canvasView.needsDisplay = true
    }
}
