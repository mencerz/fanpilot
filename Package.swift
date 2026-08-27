// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FanPilot", targets: ["FanPilot"]),
        .executable(name: "FanPilotHelper", targets: ["FanPilotHelper"])
    ],
    targets: [
        .target(
            name: "FanPilotShared",
            path: "Sources/FanPilotShared",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "FanPilot",
            dependencies: ["FanPilotShared"],
            path: "Sources/FanPilot",
            linkerSettings: [
                .linkedFramework("Charts"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                // Without a bundle — which is what Xcode and `swift run`
                // produce — macOS has no Info.plist to read, so the process is
                // not treated as an app: LSUIElement is ignored, the status
                // item is unreliable and defaults land in a stray domain.
                // Embedding the same plist in the binary fixes all three.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Resources/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "FanPilotHelper",
            dependencies: ["FanPilotShared"],
            path: "Sources/FanPilotHelper",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "FanPilotTests",
            dependencies: ["FanPilot"],
            path: "Tests/FanPilotTests"
        )
    ]
)
