// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ShelfMP3Encoder", platforms: [.iOS(.v17), .macOS(.v12)],
    products: [.library(name: "ShelfEncoder", targets: ["ShelfEncoder"])],
    targets: [
        .target(name: "LAME", path: "LAME", exclude: ["COPYING"], publicHeadersPath: "include",
                cSettings: [.define("HAVE_CONFIG_H")]),
        .target(name: "ShelfEncoder", dependencies: ["LAME"], path: "Adapter", publicHeadersPath: "include")])
