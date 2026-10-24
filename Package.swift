// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "SeearDemo", platforms: [.macOS(.v14)], targets: [
    .target(name: "SeearCore"),
    .testTarget(name: "SeearCoreTests", dependencies: ["SeearCore"])
])
