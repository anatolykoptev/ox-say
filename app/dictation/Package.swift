// swift-tools-version:5.10
// OxSay Dictation: hold a key, speak, and the text appears where the cursor is.
// DictationCore holds the logic that can be tested without a microphone, a hotkey
// or a real pasteboard; OxSayDictation is the menu-bar app around it.
import PackageDescription

let package = Package(
    name: "OxSayDictation",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "DictationCore"),
        .executableTarget(name: "OxSayDictation", dependencies: ["DictationCore"]),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
    ]
)
