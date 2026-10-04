// swift-tools-version: 6.2
import PackageDescription
import Foundation

let sdkLibrary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".runtime/nemo/lib").path
let plaudFrameworks = ProcessInfo.processInfo.environment["WORKSCRIBE_PLAUD_FRAMEWORKS"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/WorkScribe/PlaudNativeLab/Frameworks").path
let plaudSwift: [SwiftSetting] = [.unsafeFlags(["-F", plaudFrameworks])]


let package = Package(
    name: "WorkScribe",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WorkScribe", targets: ["WorkScribe"])],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: [])],
    targets: [
        .target(name: "COpus", path: "experiments/plaud-macos/Sources/COpus", publicHeadersPath: "."),
        .target(name: "WorkScribePlaud", dependencies: ["COpus"], path: "experiments/plaud-macos/Sources",
            exclude: ["NativeLab.swift", "NativeSpeech.swift", "BLETrace.swift", "COpus"],
            sources: ["PlaudAuth.swift", "EncryptedStream.swift", "NativeAudio.swift", "OpusPacketDecoder.swift", "HandoffBLEDelegate.swift", "HandoffReceipt.swift", "PlaudIdentity.swift", "PlaudHandoffController.swift"],
            swiftSettings: plaudSwift, linkerSettings: [.unsafeFlags(["-F", plaudFrameworks, "-framework", "PlaudBleSDK", "-framework", "PlaudDeviceBasicSDK", "-Xlinker", "-rpath", "-Xlinker", plaudFrameworks])]),
        .target(name: "CTextGeneration", linkerSettings: [
            .unsafeFlags(["-L", sdkLibrary]), .linkedLibrary("llama")
        ]),
        .target(name: "CNemo", linkerSettings: [
            .unsafeFlags(["-L", sdkLibrary, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                          "-Xlinker", "-rpath", "-Xlinker", sdkLibrary]),
            .linkedLibrary("nemo_speech_asr_c")
        ]),
        .target(name: "WorkScribeCore"),
        .executableTarget(name: "WorkScribe", dependencies: ["WorkScribeCore", "WorkScribePlaud", "CNemo", "CTextGeneration", .product(name: "FluidAudio", package: "FluidAudio")], swiftSettings: plaudSwift),
        .testTarget(name: "WorkScribeCoreTests", dependencies: ["WorkScribeCore"]),
        .testTarget(name: "WorkScribePlaudTests", dependencies: ["WorkScribePlaud"], swiftSettings: plaudSwift),
        .testTarget(name: "WorkScribeTests", dependencies: ["WorkScribe", "WorkScribeCore"], swiftSettings: plaudSwift)
    ], swiftLanguageModes: [.v5], cxxLanguageStandard: .cxx17
)
