// swift-tools-version:5.10
// Screenshot harness for the main window: renders MainWindowUI with sample data to PNGs.
// Not part of the app or its build. Run: app/dictation/Shots/render.sh
import PackageDescription

let package = Package(
    name: "OxSayShots",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(name: "OxSayShots", dependencies: [
            .product(name: "MainWindowUI", package: "dictation"),
        ]),
    ]
)
