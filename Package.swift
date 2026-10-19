// swift-tools-version: 6.2
import PackageDescription
import Foundation

let runtimeHome = ProcessInfo.processInfo.environment["WORKSCRIBE_RUNTIME_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorkScribe/Runtime").path
let sdkLibrary = runtimeHome + "/nemo/lib"
let plaudFrameworks = ProcessInfo.processInfo.environment["WORKSCRIBE_PLAUD_FRAMEWORKS"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/WorkScribe/PlaudNativeLab/Frameworks").path
let plaudEnabled = ProcessInfo.processInfo.environment["WORKSCRIBE_PLAUD"] == "1"
let plaudSwift: [SwiftSetting] = plaudEnabled ? [.define("WORKSCRIBE_PLAUD"), .unsafeFlags(["-F", plaudFrameworks])] : []
let appDependencies: [Target.Dependency] = ["WorkScribeCore", "CNemo", "CTextGeneration", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "FluidUse", package: "FluidUse")] + (plaudEnabled ? ["WorkScribePlaud"] : [])


let package = Package(
    name: "WorkScribe",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "WorkScribe", targets: ["WorkScribe"]),
               .executable(name: "WorkScribeNativeHost", targets: ["WorkScribeNativeHost"]),
               .executable(name: "WorkScribeVectorBench", targets: ["WorkScribeVectorBench"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: []),
        // EmbeddingGemma 2 on Core ML (text on the Neural Engine, audio on the GPU). Not tagged yet: pin the commit.
        .package(url: "https://github.com/FluidInference/FluidUse.git", revision: "d278e17df85e39e8c21bb64a467da81c39576fcd")
    ],
    targets: [
        .target(name: "CTextGeneration", linkerSettings: [
            .unsafeFlags(["-L", sdkLibrary]), .linkedLibrary("llama")
        ]),
        .target(name: "CNemo", linkerSettings: [
            .unsafeFlags(["-L", sdkLibrary, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                          "-Xlinker", "-rpath", "-Xlinker", sdkLibrary]),
            .linkedLibrary("nemo_speech_asr_c")
        ]),
        .target(name: "WorkScribeCore", resources: [.copy("Resources/decision-head.json")]),
        .executableTarget(name: "WorkScribeVectorBench", dependencies: ["WorkScribeCore"]),
        // Browser native-messaging host for the clip extension (extras/chrome-extension); bundled in Contents/Helpers.
        .executableTarget(name: "WorkScribeNativeHost", dependencies: ["WorkScribeCore"]),
        .executableTarget(name: "WorkScribe", dependencies: appDependencies, swiftSettings: plaudSwift),
        .testTarget(name: "WorkScribeCoreTests", dependencies: ["WorkScribeCore"], resources: [.copy("Golden")]),
        .testTarget(name: "WorkScribeTests", dependencies: ["WorkScribe", "WorkScribeCore"], swiftSettings: plaudSwift)
    ] + (plaudEnabled ? [
        .target(name: "COpus", path: "experiments/plaud-macos/Sources/COpus", publicHeadersPath: "."),
        .target(name: "WorkScribePlaud", dependencies: ["COpus"], path: "experiments/plaud-macos/Sources",
            exclude: ["NativeLab.swift", "NativeSpeech.swift", "BLETrace.swift", "COpus"],
            sources: ["PlaudAuth.swift", "EncryptedStream.swift", "NativeAudio.swift", "OpusPacketDecoder.swift", "HandoffBLEDelegate.swift", "HandoffReceipt.swift", "PlaudIdentity.swift", "PlaudHandoffController.swift"],
            swiftSettings: plaudSwift, linkerSettings: [.unsafeFlags(["-F", plaudFrameworks, "-framework", "PlaudBleSDK", "-framework", "PlaudDeviceBasicSDK", "-Xlinker", "-rpath", "-Xlinker", plaudFrameworks])]),
        .testTarget(name: "WorkScribePlaudTests", dependencies: ["WorkScribePlaud"], swiftSettings: plaudSwift)
    ] : []), swiftLanguageModes: [.v5], cxxLanguageStandard: .cxx17
)
