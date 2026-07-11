// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WizCinema",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "WizCinema", targets: ["WizCinema"])
    ],
    targets: [
        .executableTarget(
            name: "WizCinema",
            path: "Sources/WizCinema"
        )
    ]
)
