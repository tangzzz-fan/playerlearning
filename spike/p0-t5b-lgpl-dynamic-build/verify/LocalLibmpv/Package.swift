// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalLibmpv",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "Libmpv", targets: ["Libmpv"])
    ],
    targets: [
        .binaryTarget(name: "Libmpv", path: "Libmpv.xcframework")
    ]
)
