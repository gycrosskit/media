// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GycMedia", platforms: [.iOS(.v14)], products: [
    .library(name: "GycMedia", targets: ["GycMedia"])
], targets: [.target(name: "GycMedia", path: "iosApp/Sources/GycMedia")])
