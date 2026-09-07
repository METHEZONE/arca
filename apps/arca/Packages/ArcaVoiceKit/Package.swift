// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "ArcaVoiceKit",
    platforms: [
        .macOS("15.0"),
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
        // Body + focus domain: pure scoring and profiling, no HealthKit, so it
        // compiles and unit-tests on the Mac where HealthKit doesn't exist.
        .target(name: "Vitals", dependencies: ["ArcaVoiceCore"]),
        .target(name: "Intelligence", dependencies: ["ArcaVoiceCore", "Store", "Vitals"]),
        .target(
            name: "ArcaVoiceKit",
            dependencies: ["ArcaVoiceCore", "Capture", "Calling", "Transcribe", "Diarize", "Intelligence", "Store", "Vitals"]
        ),
        .testTarget(name: "ArcaVoiceKitTests",
                    dependencies: ["ArcaVoiceKit", "ArcaVoiceCore", "Vitals", "Calling", "Intelligence"]),
    ]
)
