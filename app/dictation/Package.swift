// swift-tools-version:5.10
// OxSay Dictation: hold a key, speak, and the text appears where the cursor is.
// DictationCore holds the logic that can be tested without a microphone, a hotkey
// or a real pasteboard; MainWindowUI holds the main window's SwiftUI views, which
// take plain data and call closures (so they render without the app); OxSayDictation
// is the menu-bar app around them.
import PackageDescription

let package = Package(
    name: "OxSayDictation",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MainWindowUI", targets: ["MainWindowUI"]),
    ],
    targets: [
        .target(name: "DictationCore"),
        .target(name: "MainWindowUI", dependencies: ["DictationCore"]),
        .executableTarget(name: "OxSayDictation", dependencies: ["DictationCore", "MainWindowUI"]),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
    ]
)
