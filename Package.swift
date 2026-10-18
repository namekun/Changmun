// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Changmun",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Changmun", targets: ["Changmun"]),
    ],
    targets: [
        // Apple's on-device model is there from macOS 26; on older systems tidying goes without it.
        .executableTarget(name: "Changmun", path: "Sources/Changmun",
                          linkerSettings: [.unsafeFlags(["-weak_framework", "FoundationModels"])]),
        .testTarget(name: "ChangmunTests", dependencies: ["Changmun"], path: "Tests/ChangmunTests"),
    ]
)
