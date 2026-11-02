// swift-tools-version: 6.2
// ox-diar: one-shot speaker diarization on FluidAudio's CoreML port of the pyannote community-1 pipeline.
// Tools 6.2 because `traits:` (below) needs it; the build runs on Xcode 26 (release.yml selects it).
import PackageDescription

let package = Package(
    name: "ox-diar",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Exact release, no range. traits: ["Diarizer"] because 0.18 compiles diarization out unless the trait is named
        // (the default set also carries TTS and NemoTextProcessing, which we do not use; an explicit list replaces it).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0", traits: ["Diarizer"]),
    ],
    targets: [
        // Everything that needs no model file: the OS gate, the pinned configuration, the audio reader and the JSON
        // the daemon reads. Linking FluidAudio here (types only) lets `swift test` pin the configuration.
        .target(name: "OxDiarCore", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "ox-diar", dependencies: ["OxDiarCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "OxDiarCoreTests", dependencies: ["OxDiarCore", .product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
