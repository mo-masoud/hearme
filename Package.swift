// swift-tools-version:5.10
import PackageDescription

let libDir = Context.packageDirectory + "/Vendor/lib"

let package = Package(
    name: "HearMe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CTranscribe", path: "Sources/CTranscribe"),
        .executableTarget(
            name: "HearMe",
            dependencies: ["CTranscribe"],
            path: "Sources/HearMe",
            linkerSettings: [
                .unsafeFlags([
                    "-L", libDir, "-ltranscribe",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
    ]
)
