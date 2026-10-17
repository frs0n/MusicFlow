// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MusicFlow", platforms: [.macOS(.v14)], targets: [
    .executableTarget(name: "MusicFlow", resources: [.copy("Resources")], linkerSettings: [
        .linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("MetalPerformanceShaders")
    ])
])
