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
        ),
        .executable(
            name: "GoogleHomeCameraWidgetExtension",
            targets: ["GoogleHomeCameraWidgetExtension"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "GoogleHomeCameraWidget",
            dependencies: [],
            path: "Sources",
            exclude: ["GoogleHomeCameraWidgetExtension"],
            sources: ["main.swift"]
        ),
        .executableTarget(
            name: "GoogleHomeCameraWidgetExtension",
            dependencies: [],
            path: "Sources/GoogleHomeCameraWidgetExtension"
        )
    ]
)
