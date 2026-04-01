// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FFmpegKit",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "FFmpegKit", targets: ["FFmpegKit"]),
    ],
    targets: [
        // Merged FFmpeg static library (libavformat + libavcodec + libavutil + libswresample).
        // Run `scripts/build-ffmpeg.sh` from the project root to generate this.
        .binaryTarget(name: "FFmpeg", path: "Frameworks/FFmpeg.xcframework"),

        // Swift wrappers for FFmpeg C APIs.
        .target(
            name: "FFmpegKit",
            dependencies: ["FFmpeg"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]
        ),
    ]
)
