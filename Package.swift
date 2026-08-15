// swift-tools-version:6.0

import PackageDescription

let upcomingFeatures: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
  name: "AsyncLineReader",
  platforms: [
    .macOS(.v15),
  ],
  products: [
    .library(
      name: "AsyncLineReader",
      targets: ["AsyncLineReader"]
    ),
    .executable(
      name: "line-reader-demo",
      targets: ["line-reader-demo"]
    ),
  ],
  targets: [
    .target(
      name: "AsyncLineReader",
      swiftSettings: upcomingFeatures
    ),
    .executableTarget(
      name: "line-reader-demo",
      dependencies: ["AsyncLineReader"],
      swiftSettings: upcomingFeatures
    ),
    .testTarget(
      name: "AsyncLineReaderTests",
      dependencies: ["AsyncLineReader"],
      swiftSettings: upcomingFeatures
    ),
  ]
)
