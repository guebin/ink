import Cocoa
import WebKit
import UniformTypeIdentifiers

/// Ink has one implementation: the board lives in `docs/` as web code, shared
/// by the website and this app. This file is the native shell around it — a
/// window, the menus, file panels, and .ink document handling.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKScriptMessageHandler, WKNavigationDelegate {

    private var window: NSWindow!
    private var web: WKWebView!

    private var documentURL: URL?
    private var dirty = false
    private var pendingOpenURL: URL?
    private var webReady = false

    private static let inkType =
        UTType(filenameExtension: "ink", conformingTo: .json) ?? .json

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "ink")
        // Without this every local script is its own opaque origin, so any
        // failure inside the board reports as a bare "Script error." with no
        // file or line.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        if #available(macOS 13.3, *) { web.isInspectable = true }

        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: min(1500, vis.width * 0.9),
                                height: min(980, vis.height * 0.9)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Ink"
        window.contentView = web
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        guard let dir = Self.webRoot() else {
            let alert = NSAlert()
            alert.messageText = "Ink의 웹 리소스를 찾을 수 없습니다."
            alert.informativeText = "앱 번들이 손상된 것 같습니다. 다시 설치해 주세요."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        web.loadFileURL(dir.appendingPathComponent("index.html"),
                        allowingReadAccessTo: dir)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The board's web files: inside the app bundle normally, or the repo's
    /// `docs/` when running straight out of `.build` during development.
    private static func webRoot() -> URL? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web"),
           fm.fileExists(atPath: r.appendingPathComponent("index.html").path) {
            return r
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("docs")
            if fm.fileExists(atPath: candidate.appendingPathComponent("index.html").path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webReady = true
        // `Ink --export-test board.ink out.png` exercises the snapshot export
        // without a save panel, so it can be checked from a script.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-test"), args.count > i + 2 {
            let board = URL(fileURLWithPath: args[i + 1])
            let out = URL(fileURLWithPath: args[i + 2])
            load(url: board)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                self.board("return inkNative.prepareSnapshot()") { value in
                    guard let r = value as? [String: Any],
                          let x = (r["x"] as? NSNumber)?.doubleValue,
                          let y = (r["y"] as? NSNumber)?.doubleValue,
                          let w = (r["w"] as? NSNumber)?.doubleValue,
                          let h = (r["h"] as? NSNumber)?.doubleValue else {
                        print("EXPORT TEST: empty board"); exit(1)
                    }
                    let config = WKSnapshotConfiguration()
                    config.rect = CGRect(x: x, y: y, width: w, height: h)
                    self.web.takeSnapshot(with: config) { image, error in
                        guard let image,
                              let tiff = image.tiffRepresentation,
                              let rep = NSBitmapImageRep(data: tiff),
                              let data = rep.representation(using: .png, properties: [:]) else {
                            print("EXPORT TEST failed: \(error?.localizedDescription ?? "no image")")
                            exit(1)
                        }
                        try? data.write(to: out)
                        print("EXPORT TEST: \(rep.pixelsWide)x\(rep.pixelsHigh), \(data.count) bytes")
                        exit(0)
                    }
                }
            }
            return
        }
        if let pending = pendingOpenURL {
            pendingOpenURL = nil
            load(url: pending)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmDiscardIfDirty() else { return false }
        dirty = false   // closing quits the app; don't ask again on terminate
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmDiscardIfDirty() ? .terminateNow : .terminateCancel
    }

    /// Finder double-click / `open -a Ink file.ink`. Can arrive before the
    /// page has loaded, so queue it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == "ink" }) ?? urls.first
        else { return }
        guard webReady else { pendingOpenURL = url; return }
        guard confirmDiscardIfDirty() else { return }
        load(url: url)
    }

    // MARK: - Bridge

    /// Messages the board posts, e.g. `{ type: "dirty", value: true }`.
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "dirty":
            dirty = (body["value"] as? Bool) ?? true
            window.isDocumentEdited = dirty
        case "error":
            NSLog("Ink board error — %@", (body["text"] as? String) ?? "?")
        default:
            break
        }
    }

    /// Call into the board and hand back whatever it returns (it may await).
    private func board(_ js: String, then: ((Any?) -> Void)? = nil) {
        web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): then?(value)
            case .failure(let error):
                NSLog("Ink bridge failed: %@ — %@", js, error.localizedDescription)
                then?(nil)
            }
        }
    }

    // MARK: - Documents

    private func load(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let data = try? JSONEncoder().encode(text),
              let json = String(data: data, encoding: .utf8)
        else { NSSound.beep(); return }
        board("return inkNative.load(\(json))") { [weak self] _ in
            guard let self else { return }
            self.documentURL = url
            self.window.title = url.lastPathComponent
            self.markClean()
        }
    }

    private func markClean() {
        dirty = false
        window.isDocumentEdited = false
    }

    @objc private func newDocument(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        board("return inkNative.newBoard()") { [weak self] _ in
            self?.documentURL = nil
            self?.window.title = "Ink"
            self?.markClean()
        }
    }

    @objc private func openDocument(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.inkType]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.load(url: url)
        }
    }

    @objc private func saveDocument(_ sender: Any?) {
        if let url = documentURL { write(to: url) } else { saveAs(nil) }
    }

    @objc private func saveAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.inkType]
        panel.nameFieldStringValue = documentURL?.lastPathComponent ?? "Untitled.ink"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        board("return await inkNative.serialize()") { [weak self] value in
            guard let self, let json = value as? String else { NSSound.beep(); return }
            do {
                try json.write(to: url, atomically: true, encoding: .utf8)
                self.documentURL = url
                self.window.title = url.lastPathComponent
                self.markClean()
            } catch {
                NSSound.beep()
            }
        }
    }

    /// Photograph the web view rather than re-drawing the board: what the
    /// snapshot carries is exactly what's on screen, fonts and KaTeX layout
    /// included, which a canvas re-draw only approximates.
    @objc private func exportPNG(_ sender: Any?) {
        board("return inkNative.prepareSnapshot()") { [weak self] value in
            guard let self else { return }
            // nil means the board is empty — nothing to photograph
            guard let r = value as? [String: Any],
                  let x = (r["x"] as? NSNumber)?.doubleValue,
                  let y = (r["y"] as? NSNumber)?.doubleValue,
                  let w = (r["w"] as? NSNumber)?.doubleValue,
                  let h = (r["h"] as? NSNumber)?.doubleValue, w > 1, h > 1
            else {
                self.board("return inkNative.endSnapshot()")
                NSSound.beep()
                return
            }
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: x, y: y, width: w, height: h)
            self.web.takeSnapshot(with: config) { image, _ in
                self.board("return inkNative.endSnapshot()")
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: .png, properties: [:])
                else { NSSound.beep(); return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue =
                    (self.documentURL?.deletingPathExtension().lastPathComponent ?? "Ink") + ".png"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url)
                    NSLog("Ink exported %d bytes to %@", data.count, url.path)
                } catch {
                    NSLog("Ink export failed: %@", error.localizedDescription)
                    NSSound.beep()
                }
            }
        }
    }

    /// Save-on-quit prompt. Returns true when it's safe to proceed.
    private func confirmDiscardIfDirty() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "변경 사항을 저장할까요?"
        alert.informativeText = "저장하지 않으면 지금 보드의 내용이 사라집니다."
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "저장 안 함")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // serializing the board is asynchronous, so this can't block until
            // the file lands — save now and let the user close again
            saveDocument(nil)
            return false
        case .alertSecondButtonReturn:
            return false
        default:
            return true
        }
    }

    // MARK: - Edit / View

    @objc private func undo(_ sender: Any?) { board("return inkNative.undo()") }
    @objc private func redo(_ sender: Any?) { board("return inkNative.redo()") }
    @objc private func zoomIn(_ sender: Any?) { board("return inkNative.zoomBy(1.25)") }
    @objc private func zoomOut(_ sender: Any?) { board("return inkNative.zoomBy(0.8)") }
    @objc private func zoomActual(_ sender: Any?) { board("return inkNative.setZoom(1)") }
    @objc private func zoomFit(_ sender: Any?) { board("return inkNative.zoomToFit()") }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Ink 정보",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ink 종료",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu
        main.addItem(appItem)

        let fileMenu = NSMenu(title: "파일")
        add(fileMenu, "새로 만들기", #selector(newDocument(_:)), "n")
        add(fileMenu, "열기…", #selector(openDocument(_:)), "o")
        fileMenu.addItem(.separator())
        add(fileMenu, "저장", #selector(saveDocument(_:)), "s")
        add(fileMenu, "다른 이름으로 저장…", #selector(saveAs(_:)), "s", [.command, .shift])
        fileMenu.addItem(.separator())
        add(fileMenu, "PNG로 내보내기…", #selector(exportPNG(_:)), "e", [.command, .shift])
        let fileItem = NSMenuItem(); fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editMenu = NSMenu(title: "편집")
        add(editMenu, "실행 취소", #selector(undo(_:)), "z")
        add(editMenu, "다시 실행", #selector(redo(_:)), "z", [.command, .shift])
        editMenu.addItem(.separator())
        // nil target: the web view handles these through the responder chain
        editMenu.addItem(withTitle: "잘라내기", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        let editItem = NSMenuItem(); editItem.submenu = editMenu
        main.addItem(editItem)

        let viewMenu = NSMenu(title: "보기")
        add(viewMenu, "확대", #selector(zoomIn(_:)), "+")
        add(viewMenu, "축소", #selector(zoomOut(_:)), "-")
        add(viewMenu, "실제 크기", #selector(zoomActual(_:)), "0")
        add(viewMenu, "화면에 맞추기", #selector(zoomFit(_:)), "9")
        let viewItem = NSMenuItem(); viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                     _ mask: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        item.target = self
        return item
    }
}
