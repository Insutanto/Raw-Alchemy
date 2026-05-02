// swift-tools-version: 5.9
// RawAlchemySwift – Swift port of the core Raw Alchemy processing pipeline
//
// Modules:
//   1. CLibRaw          – system-library bridge to libraw (C)
//   2. RawAlchemyKit    – Swift framework implementing:
//        • Exposure metering  (曝光测光)
//        • Color matrix + Log curve  (色彩矩阵 + Log 曲线)
//        • Tetrahedral LUT interpolation  (LUT 四面体插值)
//        • RAW decoding via libraw  (RAW 解码)
//        • End-to-end RAW → Log pipeline

import PackageDescription

let package = Package(
    name: "RawAlchemySwift",
    platforms: [
        .macOS(.v13),
        // iOS 16: ships with CIRAWFilter (iOS 15+) and CGColorSpace.rommrgbLinear (iOS 12+)
        // for the native CoreImage-based RAW decoding backend.
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "RawAlchemyKit",
            targets: ["RawAlchemyKit"]
        ),
    ],
    targets: [
        // ── C Bridge ─────────────────────────────────────────────────────────
        // Requires libraw to be installed (brew install libraw / apt-get install libraw-dev).
        .systemLibrary(
            name: "CLibRaw",
            pkgConfig: "libraw",
            providers: [
                .brew(["libraw"]),
                .apt(["libraw-dev"]),
            ]
        ),

        // ── Swift Framework ───────────────────────────────────────────────────
        .target(
            name: "RawAlchemyKit",
            dependencies: [
                // CLibRaw (libraw C bridge) is available on macOS (brew) and
                // Linux (apt).  On iOS the RAW decoding backend uses
                // CoreImage's CIRAWFilter instead.
                .target(name: "CLibRaw", condition: .when(platforms: [.macOS, .linux])),
            ]
        ),

        // ── Tests ─────────────────────────────────────────────────────────────
        .testTarget(
            name: "RawAlchemyKitTests",
            dependencies: ["RawAlchemyKit"]
        ),
    ]
)
