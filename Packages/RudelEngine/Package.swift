// swift-tools-version: 6.0
import PackageDescription

// RudelEngine ist die isolierte Berechnungs-Einheit (PRD §7).
// Bewusst OHNE SwiftData/SwiftUI-Abhängigkeit: nur Foundation.
// Die @Model-Typen der App sind Adapter, die Werte in die Engine hineingeben.
// Deployment-Targets absichtlich niedriger als das App-Target, damit
// `swift test` auch ohne Xcode-Simulator auf dem Host läuft.
let package = Package(
    name: "RudelEngine",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "RudelEngine", targets: ["RudelEngine"]),
    ],
    targets: [
        .target(
            name: "RudelEngine",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "RudelEngineTests",
            dependencies: ["RudelEngine"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
