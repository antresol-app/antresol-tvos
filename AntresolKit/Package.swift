// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AntresolKit",
    platforms: [.tvOS(.v17), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AntresolKit", targets: ["AntresolKit"]),
    ],
    targets: [
        .target(name: "AntresolKit"),
        .testTarget(
            name: "AntresolKitTests",
            dependencies: ["AntresolKit"],
            resources: [.copy("Samples")]
        ),
    ]
)
