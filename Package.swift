// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GimbalTracking",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "GimbalTracking", targets: ["GimbalTracking"]),
        .executable(name: "tracking-demo", targets: ["TrackingDemo"])
    ],
    targets: [
        .target(name: "GimbalTracking"),
        .executableTarget(name: "TrackingDemo", dependencies: ["GimbalTracking"], path: "Examples/TrackingDemo"),
        .testTarget(name: "GimbalTrackingTests", dependencies: ["GimbalTracking"])
    ]
)
