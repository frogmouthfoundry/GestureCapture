//
//  ImmersiveView.swift
//  GestureCapture
//

import ARKit
import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel

    @State private var leftOverlay = HandSkeletonOverlay()
    @State private var rightOverlay = HandSkeletonOverlay()
    @State private var replayer = GestureReplayer()

    var body: some View {
        RealityView { content, attachments in
            content.add(leftOverlay.root)
            content.add(rightOverlay.root)
            content.add(replayer.root)

            if let panel = attachments.entity(for: "status") {
                panel.position = [0, 1.35, -0.8]
                content.add(panel)
            }
        } attachments: {
            Attachment(id: "status") {
                StatusPanel()
            }
        }
        .task {
            await appModel.tracking.start()
            await updateLoop()
        }
        .onDisappear {
            replayer.stop()
            appModel.tracking.stop()
        }
        .onChange(of: appModel.replayGesture?.id) {
            Task { await reloadReplay() }
        }
    }

    /// ~30 Hz: drive overlays and feed the recognition engine while testing.
    private func updateLoop() async {
        while !Task.isCancelled {
            leftOverlay.update(anchor: appModel.tracking.leftAnchor)
            rightOverlay.update(anchor: appModel.tracking.rightAnchor)

            if appModel.liveTestEnabled {
                let left = appModel.tracking.leftAnchor.flatMap(HandPose.init(anchor:))
                let right = appModel.tracking.rightAnchor.flatMap(HandPose.init(anchor:))
                if left != nil || right != nil {
                    appModel.recognition.process(frame: GestureFrame(t: 0, left: left, right: right))
                }
            }
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    private func reloadReplay() async {
        replayer.stop()
        guard let gesture = appModel.replayGesture else {
            replayer.root.children.forEach { $0.removeFromParent() }
            return
        }
        do {
            try await replayer.load(gesture: gesture, placement: AppModel.replayPlacement)
            replayer.isLooping = true
            replayer.play()
        } catch {
            appModel.lastError = "Replay: \(error.localizedDescription)"
        }
    }
}

/// Floating panel: countdown, recording progress, live-test confidences.
struct StatusPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 12) {
            switch appModel.recorder.phase {
            case .countdown(let n):
                Text("\(n)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
            case .recording(let progress):
                if appModel.activeCaptureMode == .snapshot {
                    Image(systemName: "camera.shutter.button.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                } else {
                    let duration = appModel.activeCaptureMode?.captureDuration ?? 0
                    Text(String(format: "%.1f", progress * duration))
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
            default:
                if appModel.liveTestEnabled {
                    confidenceMeters
                } else if appModel.replayGesture != nil {
                    Label(appModel.replayGesture!.name, systemImage: "play.circle")
                        .font(.title3)
                } else {
                    Label("Hands tracked — ready to record", systemImage: "hand.raised")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 300)
        .glassBackgroundEffect()
    }

    private var confidenceMeters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Test").font(.headline)
            if appModel.recognition.confidences.isEmpty {
                Text("No gestures loaded").foregroundStyle(.secondary)
            }
            ForEach(appModel.recognition.confidences) { item in
                HStack {
                    Text(item.name)
                        .frame(width: 130, alignment: .leading)
                        .lineLimit(1)
                    ProgressView(value: item.confidence)
                        .tint(item.isActive ? .green : .blue)
                        .frame(width: 140)
                    if item.isActive {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .font(.caption)
            }
            if !appModel.lastEventDescription.isEmpty {
                Text(appModel.lastEventDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
