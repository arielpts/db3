// swift-tools-version: 6.2
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let vendor = root.appendingPathComponent("Vendor/PostgreSQL").path
let package = Package(
    name: "DB3Kit",
    platforms: [.macOS("26.0")],
    products: ["DB3Core", "DB3Postgres", "DB3Results", "DB3Editor", "DB3Grid"].map { .library(name: $0, targets: [$0]) } + [.executable(name: "db3-bench", targets: ["DB3Bench"])],
    targets: [
        .target(name: "DB3Core"),
        .systemLibrary(name: "CLibPQ"),
        .target(name: "DB3Postgres", dependencies: ["DB3Core", "CLibPQ"], swiftSettings: [.unsafeFlags(["-Xcc", "-I" + vendor + "/include"])], linkerSettings: [.unsafeFlags(["-L" + vendor + "/lib", "-Xlinker", "-rpath", "-Xlinker", vendor + "/lib"])]),
        .target(name: "DB3Results", dependencies: ["DB3Core"]),
        .target(name: "DB3Editor", dependencies: ["DB3Core"]),
        .target(name: "DB3Grid", dependencies: ["DB3Core", "DB3Results"]),
        .executableTarget(name: "DB3Bench", dependencies: ["DB3Core", "DB3Postgres", "DB3Results"]),
        .testTarget(name: "DB3CoreTests", dependencies: ["DB3Core", "DB3Postgres", "DB3Results"]),
        .testTarget(name: "DB3GridTests", dependencies: ["DB3Grid"]),
        .testTarget(name: "DB3EditorTests", dependencies: ["DB3Editor"]),
    ],
    swiftLanguageModes: [.v6]
)
