// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CastTVShared",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CastTVShared", targets: ["CastTVShared"]),
    ],
    targets: [
        .target(name: "CastTVShared"),
        .testTarget(name: "CastTVSharedTests", dependencies: ["CastTVShared"]),
    ]
)
