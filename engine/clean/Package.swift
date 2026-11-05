// swift-tools-version: 6.2
// ox-clean: offline voice cleanup (MossFormer2_SE_48K on Core ML). Tasks 3-7: the core, the Core ML mask model and the
// cleaning pipeline; Task 8 adds the executable. Tools 6.2 to match engine/diar (Xcode 26).
import PackageDescription

let package = Package(
    name: "ox-clean",
    platforms: [.macOS(.v14)],
    targets: [
        // The pin, the OS gate, the command line, the WAV reader/writer, the DSP, the Core ML runner and the pipeline.
        .target(name: "OxCleanCore"),
        // The command line: parse, gates, one cleaning run, the stats line, signals. Thin on purpose.
        .executableTarget(name: "ox-clean", dependencies: ["OxCleanCore"]),
        .testTarget(name: "OxCleanCoreTests", dependencies: ["OxCleanCore"]),
    ]
)
