// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MicPriority",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MicPriority", targets: ["MicPriority"]),
        .executable(name: "RoutingChecks", targets: ["RoutingChecks"])
    ],
    targets: [
        .target(name: "MicPriorityCore", linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("IOKit"), .linkedFramework("IOUSBHost")]),
        .executableTarget(name: "MicPriority", dependencies: ["MicPriorityCore"]),
        .executableTarget(name: "RoutingChecks", dependencies: ["MicPriorityCore"], path: "Checks")
    ]
)
