//
//  AppModel.swift
//  GestureCapture
//

import Foundation
import SwiftUI
import simd

/// Maintains app-wide state: tracking, recording, library, recognition, replay.
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    // GestureKit services
    let tracking = HandTrackingService()
    let recorder: GestureRecorder
    let store = GestureStore()
    let recognition = GestureRecognitionEngine()

    // Capture configuration (window UI)
    var captureMode: CaptureMode = .snapshot
    var captureHandedness: Handedness = .either
    var orientationSensitive = false
    var saveToPhotos = true

    // Save flow: set when a take finishes; drives the naming sheet.
    var pendingTake: GestureSample?
    /// When set, the pending take is appended to this gesture instead of creating a new one.
    var appendTarget: GestureFile?

    // Live test + replay (immersive view reacts to these)
    var liveTestEnabled = false {
        didSet { if liveTestEnabled { recognition.load(gestures: store.gestures) } }
    }
    var replayGesture: GestureFile?
    var lastEventDescription = ""

    /// Most recent recognized gesture; stays until the next detection.
    struct MatchInfo: Equatable {
        var id: UUID
        var name: String
        var confidence: Float
    }
    var lastMatch: MatchInfo?

    let sounds = SoundPlayer()
    /// Mode of the capture currently in flight (may differ from the picker
    /// when appending a take to an existing gesture).
    private(set) var activeCaptureMode: CaptureMode?

    // Preview generation status keyed by gesture id.
    var previewBusy: Set<UUID> = []
    var lastError: String?

    init() {
        recorder = GestureRecorder(tracking: tracking)
        recognition.onEvent = { [weak self] event in
            let kind = event.kind == .began ? "began" : "ended"
            self?.lastEventDescription =
                "\(event.gestureName) \(kind) (\(Int(event.confidence * 100))%)"
            if event.kind == .began {
                self?.lastMatch = MatchInfo(id: event.gestureID,
                                            name: event.gestureName,
                                            confidence: event.confidence)
            }
        }
    }

    /// Sound + save-flow side effects; call from UI onChange of recorder.phase.
    func recorderPhaseChanged(from old: GestureRecorder.Phase, to new: GestureRecorder.Phase) {
        switch new {
        case .recording:
            if case .recording = old { break }
            sounds.play(activeCaptureMode == .snapshot ? .shutter : .registerNotification)
        case .finished:
            if activeCaptureMode != .snapshot {
                sounds.play(.successNotification)
            }
            // Small delay so the end-flash and sound land before the naming sheet.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                collectFinishedTake()
            }
        default:
            break
        }
    }

    var recordingConfig: RecordingConfig {
        RecordingConfig(mode: captureMode,
                        handedness: captureHandedness,
                        orientationSensitive: orientationSensitive)
    }

    func startRecording(appendingTo target: GestureFile? = nil) {
        appendTarget = target
        if let target {
            // Takes appended to a gesture must match how it was recorded.
            let mode: CaptureMode = target.type == .pose ? .snapshot : captureMode
            activeCaptureMode = mode
            recorder.record(config: RecordingConfig(
                mode: mode,
                handedness: target.handedness,
                orientationSensitive: target.orientationSensitive))
        } else {
            activeCaptureMode = captureMode
            recorder.record(config: recordingConfig)
        }
    }

    /// Called by UI when recorder phase hits .finished.
    func collectFinishedTake() {
        guard let take = recorder.takeResult() else { return }
        if var target = appendTarget {
            appendTarget = nil
            target.samples.append(take)
            do {
                try store.save(target)
                regeneratePreviews(for: target)
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            pendingTake = take   // triggers naming sheet
        }
    }

    func savePendingTake(named name: String) {
        guard let take = pendingTake else { return }
        pendingTake = nil
        var gesture = GestureFile(name: name,
                                  type: captureMode.gestureType,
                                  handedness: captureHandedness,
                                  orientationSensitive: orientationSensitive,
                                  sampleRate: GestureRecorder.storedFPS)
        gesture.samples = [take]
        do {
            try store.save(gesture)
            regeneratePreviews(for: gesture)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func regeneratePreviews(for gesture: GestureFile) {
        guard !previewBusy.contains(gesture.id) else { return }
        previewBusy.insert(gesture.id)
        Task {
            defer { previewBusy.remove(gesture.id) }
            do {
                let renderer = try GesturePreviewRenderer()
                let output = try await renderer.render(
                    gesture: gesture, videoDestination: store.videoURL(for: gesture.id))
                try output.thumbnailPNG.write(to: store.thumbnailURL(for: gesture.id), options: .atomic)
                store.reload()
                if saveToPhotos {
                    try await PhotoLibrarySaver.save(pngData: output.thumbnailPNG,
                                                     videoURL: output.videoURL)
                }
            } catch {
                lastError = "Preview render: \(error.localizedDescription)"
            }
        }
    }

    /// Placement for ghost replay: ~0.6 m in front of the user at chest height.
    static let replayPlacement: simd_float4x4 = {
        var m = matrix_identity_float4x4
        m.columns.3 = [0, 1.1, -0.6, 1]
        return m
    }()
}
