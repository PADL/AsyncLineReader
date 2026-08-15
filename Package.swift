// swift-tools-version:6.0

import PackageDescription

/// Nonisolated async functions run on the caller's actor rather than hopping to the concurrent
/// executor, which is the default in Swift 7: it saves a hop per keystroke here, and the reader
/// has nothing that wants to be moved off the caller.
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
