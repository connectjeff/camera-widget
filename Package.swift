// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GoogleHomeCameraWidget",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "GoogleHomeCameraWidget",
            targets: ["GoogleHomeCameraWidget"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "GoogleHomeCameraWidget",
            dependencies: []
        )
    ]
)
