// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MilaNativeUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "MilaNativeUI", targets: ["MilaNativeUI"]),
    ],
    targets: [
        .target(
            name: "MilaNativeUI",
            path: "Sources/MilaNativeUI"
        ),
    ]
)
