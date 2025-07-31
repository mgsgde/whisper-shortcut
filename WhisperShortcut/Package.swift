// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "WhisperShortcut",
  platforms: [
    .macOS(.v12)
  ],
  products: [
    .executable(
      name: "WhisperShortcut",
      targets: ["WhisperShortcut"]
    )
  ],
  dependencies: [
    // HotKey library for global shortcuts
    .package(url: "https://github.com/soffes/HotKey", from: "0.2.0")
  ],
  targets: [
    .executableTarget(
      name: "WhisperShortcut",
      dependencies: ["HotKey"],
      path: "Sources"
    ),
    .testTarget(
      name: "WhisperShortcutTests",
      dependencies: ["WhisperShortcut"],
      path: "Tests"
    ),
  ]
)
