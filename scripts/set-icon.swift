import Cocoa

// Sets a custom Finder icon on a file/app bundle using the official API.
// usage: set-icon <imagePath> <targetPath>
guard CommandLine.arguments.count == 3,
      let img = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: set-icon <image.png> <target>\n".data(using: .utf8)!)
    exit(1)
}
let target = CommandLine.arguments[2]
let ok = NSWorkspace.shared.setIcon(img, forFile: target, options: [])
print(ok ? "set icon on \(target)" : "FAILED to set icon on \(target)")
exit(ok ? 0 : 2)
