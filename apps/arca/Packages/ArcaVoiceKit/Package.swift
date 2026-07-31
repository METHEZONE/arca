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
        // ARCA↔ARCA calling: our own audio path, so calls can be recorded with
        // headphones on and without a notification tone. See docs/calling.md.
        .target(name: "Calling", dependencies: ["ArcaVoiceCore"]),
        .target(name: "Transcribe", dependencies: ["ArcaVoiceCore"]),
        .target(name: "Diarize", dependencies: ["ArcaVoiceCore"]),
        .target(name: "Store", dependencies: ["ArcaVoiceCore"]),
        .target(name: "Intelligence", dependencies: ["ArcaVoiceCore", "Store"]),
        .target(
            name: "ArcaVoiceKit",
            dependencies: ["ArcaVoiceCore", "Capture", "Calling", "Transcribe", "Diarize", "Intelligence", "Store"]
        ),
        .testTarget(name: "ArcaVoiceKitTests",
                    dependencies: ["ArcaVoiceKit", "ArcaVoiceCore", "Calling"]),
    ]
)
