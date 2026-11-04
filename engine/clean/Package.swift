// swift-tools-version: 6.2
// ox-clean: offline voice cleanup (MossFormer2_SE_48K on Core ML). Task 3 is the dependency-free core; the Core ML
// runner (Task 7) and the executable target (Task 8) are added later. Tools 6.2 to match engine/diar (Xcode 26).
import PackageDescription

let package = Package(
    name: "ox-clean",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that needs no model file: the pin, the OS gate, the command line and the WAV reader/writer.
        .target(name: "OxCleanCore"),
        .testTarget(name: "OxCleanCoreTests", dependencies: ["OxCleanCore"]),
    ]
)
