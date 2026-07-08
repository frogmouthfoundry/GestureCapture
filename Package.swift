// swift-tools-version: 6.0
// Debug/tooling package only — the visionOS app builds from GestureCapture.xcodeproj.
// This lets GestureKit compile on macOS so Tools/RetargetLab can render the rigged
// hands locally (fast retarget-debug loop without a headset).
import PackageDescription

let package = Package(
    name: "GestureCaptureTools",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "GestureKit",
            path: "GestureCapture/GestureKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "RetargetLab",
            dependencies: ["GestureKit"],
            path: "Tools/RetargetLab",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
