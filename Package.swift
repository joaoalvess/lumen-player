// swift-tools-version:5.9
import Foundation
import PackageDescription

let package = Package(
    name: "Lumen",
    defaultLocalization: "en",
    platforms: [.macOS(.v10_15), .macCatalyst(.v14), .iOS(.v13), .tvOS(.v13)],
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "Lumen",
            // todo clang: warning: using sysroot for 'iPhoneSimulator' but targeting 'MacOSX' [-Wincompatible-sysroot]
//            type: .dynamic,
            targets: ["Lumen"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        .target(
            name: "Lumen",
            dependencies: [
                .product(name: "FFmpegKit", package: "FFmpegKit"),
                // The core has no Mac Catalyst slices; the Atmos activator is for Apple TV's HDMI output.
                .product(name: "SpatialAudioBridge", package: "SpatialAudioBridge", condition: .when(platforms: [.tvOS, .iOS, .macOS])),
                .product(name: "SpatialAudioPlayback", package: "SpatialAudioBridge", condition: .when(platforms: [.tvOS, .iOS])),
//                .product(name: "Libass", package: "FFmpegKit"),
//                .product(name: "Libmpv", package: "FFmpegKit"),
                "DisplayCriteria",
            ],
            resources: [.process("Metal/Shaders.metal")],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "DisplayCriteria"
        ),
        .testTarget(
            name: "LumenTests",
            dependencies: ["Lumen"],
            resources: [.process("Resources")]
        ),
    ]
)

package.dependencies += [
    .package(path: "FFmpegKit"),
    .package(url: "https://github.com/kristofferR/SpatialAudioBridge", from: "2.0.0"),
]
