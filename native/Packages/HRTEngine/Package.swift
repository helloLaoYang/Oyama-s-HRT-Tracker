// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HRTEngine",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [.library(name: "HRTEngine", targets: ["HRTEngine"])],
    targets: [
        .target(name: "HRTEngine"),
        .testTarget(name: "HRTEngineTests", dependencies: ["HRTEngine"], resources: [.process("Resources")])
    ]
)
