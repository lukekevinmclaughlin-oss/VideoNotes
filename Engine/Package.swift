// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SketchnoteEngine",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SketchnoteEngine", targets: ["SketchnoteEngine"])
    ],
    targets: [
        .target(name: "SketchnoteEngine"),
        .executableTarget(name: "sketchnote-cli", dependencies: ["SketchnoteEngine"]),
        .testTarget(name: "SketchnoteEngineTests", dependencies: ["SketchnoteEngine"])
    ]
)
