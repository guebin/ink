// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Paint",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "Paint",
            path: "Sources/Paint"
        ),
        // The board itself is web code in docs/, copied into the app bundle by
        // install-ink.sh — this target is only the native shell around it.
        .executableTarget(
            name: "Ink",
            path: "Sources/Ink"
        )
    ]
)
