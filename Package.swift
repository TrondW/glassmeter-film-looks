// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GlassFilmLooks",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "GlassFilmLooks", targets: ["GlassFilmLooks"]),
        .executable(name: "glassfilm", targets: ["glassfilm"]),
    ],
    targets: [
        .target(
            name: "GlassFilmLooks",
            resources: [.copy("Resources/film-stocks.json")]
        ),
        .executableTarget(
            name: "glassfilm",
            dependencies: ["GlassFilmLooks"]
        ),
        .testTarget(
            name: "GlassFilmLooksTests",
            dependencies: ["GlassFilmLooks"]
        ),
    ]
)
