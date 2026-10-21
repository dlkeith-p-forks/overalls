// swift-tools-version: 6.1

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
            name: "MilaFFIShim",
            path: "Sources/MilaFFIShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MilaNativeUI",
            dependencies: ["MilaFFIShim"],
            path: "Sources/MilaNativeUI"
        ),
        .testTarget(
            name: "MilaNativeUITests",
            dependencies: ["MilaNativeUI"],
            path: "Tests/MilaNativeUITests"
        ),
    ]
)
