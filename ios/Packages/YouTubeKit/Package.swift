// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "YouTubeKit", platforms: [.iOS(.v17), .macOS(.v13)], products: [
    .library(name: "YouTubeKit", targets: ["YouTubeKit"])
], targets: [.target(name: "YouTubeKit", exclude: ["Extensions/AsyncCompatibility.swift"], resources: [.process("Resources")])])
