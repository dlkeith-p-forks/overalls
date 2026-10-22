// swift-tools-version: 6.1

import PackageDescription
import Foundation

let rustLibDir = ProcessInfo.processInfo.environment["MILA_FFI_LIB_DIR"] ?? ""
guard !rustLibDir.isEmpty else { fatalError("MILA_FFI_LIB_DIR must point to a built mila-ffi static library") }

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
            path: "Sources/MilaNativeUI",
            resources: [.process("Resources")],
            linkerSettings: [.unsafeFlags([rustLibDir + "/libmila_ffi.a"])]
        ),
        .testTarget(
            name: "MilaNativeUITests",
            dependencies: ["MilaNativeUI"],
            path: "Tests/MilaNativeUITests"
        ),
    ]
)
