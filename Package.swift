// swift-tools-version:6.0

import PackageDescription

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
      name: "AsyncLineReader"
    ),
    .executableTarget(
      name: "line-reader-demo",
      dependencies: ["AsyncLineReader"]
    ),
    .testTarget(
      name: "AsyncLineReaderTests",
      dependencies: ["AsyncLineReader"]
    ),
  ]
)
