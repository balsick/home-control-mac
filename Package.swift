// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "HomeControl",
  platforms: [.macOS(.v14)],
  targets: [
    // Device protocols and parsing, free of UI so they can be tested.
    .target(name: "HomeCore", path: "Sources/HomeCore"),
    .executableTarget(
      name: "home-control",
      dependencies: ["HomeCore"],
      path: "Sources/HomeControl",
      linkerSettings: [
        // The binary also carries its Info.plist, so it has its usage strings
        // and bundle identifier when started on its own (`--probe`).
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
          "-Xlinker", "Info.plist",
        ])
      ]
    ),
    .testTarget(name: "HomeCoreTests", dependencies: ["HomeCore"], path: "Tests/HomeCoreTests"),
  ]
)
