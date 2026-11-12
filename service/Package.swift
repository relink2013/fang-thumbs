// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "fang-thumbs",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "fang-thumbs", targets: ["fang-thumbs"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "FangThumbsCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "fang-thumbs",
            dependencies: [
                "FangThumbsCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "FangThumbsCoreTests", dependencies: ["FangThumbsCore"]),
    ]
)
