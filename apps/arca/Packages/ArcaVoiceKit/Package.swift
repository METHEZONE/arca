// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "ArcaVoiceKit",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "ArcaVoiceKit", targets: ["ArcaVoiceKit"]),
    ],
    targets: [
        .target(name: "ArcaVoiceCore"),
        .target(name: "Capture", dependencies: ["ArcaVoiceCore"]),
        .target(name: "Transcribe", dependencies: ["ArcaVoiceCore"]),
        .target(name: "Diarize", dependencies: ["ArcaVoiceCore"]),
        .target(name: "Store", dependencies: ["ArcaVoiceCore"]),
        .target(name: "Intelligence", dependencies: ["ArcaVoiceCore", "Store"]),
        .target(
            name: "ArcaVoiceKit",
            dependencies: ["ArcaVoiceCore", "Capture", "Transcribe", "Diarize", "Intelligence", "Store"]
        ),
        .testTarget(name: "ArcaVoiceKitTests", dependencies: ["ArcaVoiceKit"]),
    ]
)
