// swift-tools-version: 6.2
import PackageDescription

// Compile the real application sources (except its entry point) for headless
// lifecycle and native view tests. Xcode remains the application bundle build.
let package = Package(
    name: "DB3WorkbenchChecks",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "Packages/DB3Kit")],
    targets: [
        .target(
            name: "DB3Workbench",
            dependencies: ["DB3Core", "DB3Postgres", "DB3Results", "DB3Editor", "DB3Grid"].map {
                .product(name: $0, package: "db3kit")
            },
            path: "App/DB3App",
            exclude: ["DB3App.swift"]
        ),
        .testTarget(name: "DB3WorkbenchTests", dependencies: [
            "DB3Workbench", .product(name: "DB3Core", package: "db3kit")
        ], path: "Tests/DB3WorkbenchTests")
    ],
    swiftLanguageModes: [.v6]
)
