// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuietType",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "QuietType", targets: ["QuietType"])],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.0.0")
    ],
    targets: [
        .target(name: "QuietTypeCore", dependencies: [
            .product(name: "Tokenizers", package: "swift-transformers")
        ]),
        .executableTarget(name: "QuietType", dependencies: ["QuietTypeCore"]),
        .executableTarget(name: "ModelProbe", dependencies: ["QuietTypeCore"]),
        .testTarget(name: "QuietTypeCoreTests", dependencies: ["QuietTypeCore"])
    ]
)
