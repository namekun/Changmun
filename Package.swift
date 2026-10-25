// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Changmun",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Changmun", targets: ["Changmun"]),
    ],
    dependencies: [
        // Updates arrive inside the app; pinned exactly, so a release is built from the Sparkle it was tested with.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // The bottom layer, which knows nothing of the app: the compiler refuses a dependency from it upward.
        .target(name: "ChangmunCore", path: "Sources/ChangmunCore"),
        // Apple's on-device model is there from macOS 26; on older systems tidying goes without it.
        .executableTarget(name: "Changmun", dependencies: ["ChangmunCore", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/Changmun",
                          linkerSettings: [.unsafeFlags(["-weak_framework", "FoundationModels"])]),
        .testTarget(name: "ChangmunTests", dependencies: ["Changmun"], path: "Tests/ChangmunTests"),
    ]
)
