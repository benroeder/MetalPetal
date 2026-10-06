// swift-tools-version:5.1

// requires SE-0271

import PackageDescription

let package = Package(
    name: "MetalPetal",
    platforms: [.macOS(.v10_13), .iOS(.v11), .tvOS(.v13)],
    products: [
        .library(
            name: "MetalPetal",
            targets: ["MetalPetal"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MetalPetal",
            dependencies: ["MetalPetalObjectiveC"]),
        .target(
            name: "MetalPetalObjectiveC",
            dependencies: []),
        //ObjC++ so it can throw a real C++ exception at the render graph —
        //Swift cannot, and a target cannot mix languages.
        .target(
            name: "MetalPetalThrowingPromise",
            dependencies: ["MetalPetalObjectiveC"],
            path: "Tests/MetalPetalThrowingPromise"),
        .target(
            name: "MetalPetalTestHelpers",
            dependencies: ["MetalPetal"],
            path: "Tests/MetalPetalTestHelpers"),
        .testTarget(
            name: "MetalPetalTests",
            dependencies: ["MetalPetal", "MetalPetalTestHelpers", "MetalPetalThrowingPromise"]),
    ],
    cxxLanguageStandard: .cxx14
)
