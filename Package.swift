// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Changmun",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Changmun", targets: ["Changmun"]),
    ],
    targets: [
        .executableTarget(name: "Changmun", path: "Sources/Changmun"),
        .testTarget(name: "ChangmunTests", dependencies: ["Changmun"], path: "Tests/ChangmunTests"),
    ]
)
