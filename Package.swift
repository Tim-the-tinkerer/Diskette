// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Diskette",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Diskette", targets: ["Diskette"]),
    ],
    targets: [
        .executableTarget(
            name: "Diskette",
            path: "Sources/Diskette"
        ),
    ]
)
