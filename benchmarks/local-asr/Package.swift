// swift-tools-version: 6.0
//
// Standalone benchmark for offline speech-to-text engines (plans/improvement-plan-2026-09.md F15).
// Deliberately outside the Xcode project: it measures candidates *before* any of them is added to
// the app, and a CLI is not sandboxed, so it can read the app container's recordings and run `say`.
import PackageDescription

let package = Package(
  name: "LocalASRBench",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.4"),
    // Same pin as the app, so the Whisper arm is the Whisper users run today.
    .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
  ],
  targets: [
    .executableTarget(
      name: "LocalASRBench",
      dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "WhisperKit", package: "WhisperKit"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
