// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "CasingExp", platforms: [.macOS(.v15)],
  dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7")],
  targets: [.executableTarget(name: "CasingExp",
    dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
    swiftSettings: [.swiftLanguageMode(.v5)])])
