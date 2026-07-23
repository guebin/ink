import Cocoa

/// Accessory view for the New / Canvas Size dialogs: a preset popup plus
/// editable width × height fields.
final class SizeAccessory: NSView {
    let widthField = NSTextField(frame: NSRect(x: 24, y: 8, width: 92, height: 24))
    let heightField = NSTextField(frame: NSRect(x: 150, y: 8, width: 92, height: 24))
    private let popup = NSPopUpButton(frame: NSRect(x: 0, y: 46, width: 266, height: 26))

    private let presets: [(String, Int, Int)] = [
        ("Custom", 0, 0),
        ("6K UHD — 6144 × 3456", 6144, 3456),
        ("Full HD — 1920 × 1080", 1920, 1080),
        ("HD — 1280 × 720", 1280, 720),
        ("4K UHD — 3840 × 2160", 3840, 2160),
        ("2K QHD — 2560 × 1440", 2560, 1440),
        ("Square — 1080 × 1080", 1080, 1080),
        ("Instagram — 1080 × 1350", 1080, 1350),
        ("A4 @150dpi — 1240 × 1754", 1240, 1754),
    ]

    init(defaultW: Int, defaultH: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 266, height: 78))
        widthField.stringValue = "\(defaultW)"
        heightField.stringValue = "\(defaultH)"

        popup.addItems(withTitles: presets.map { $0.0 })
        popup.target = self
        popup.action = #selector(presetChanged)
        // preselect a matching preset if the default size matches one
        if let i = presets.firstIndex(where: { $0.1 == defaultW && $0.2 == defaultH }) {
            popup.selectItem(at: i)
        }

        let wl = NSTextField(labelWithString: "W")
        wl.frame = NSRect(x: 4, y: 11, width: 18, height: 18)
        let x = NSTextField(labelWithString: "×")
        x.frame = NSRect(x: 122, y: 11, width: 18, height: 18)

        addSubview(popup)
        addSubview(wl); addSubview(widthField)
        addSubview(x); addSubview(heightField)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func presetChanged() {
        let p = presets[popup.indexOfSelectedItem]
        guard p.1 > 0 else { return } // "Custom" keeps current fields
        widthField.stringValue = "\(p.1)"
        heightField.stringValue = "\(p.2)"
    }

    var chosenSize: (Int, Int) {
        (Int(widthField.stringValue) ?? 0, Int(heightField.stringValue) ?? 0)
    }
}
