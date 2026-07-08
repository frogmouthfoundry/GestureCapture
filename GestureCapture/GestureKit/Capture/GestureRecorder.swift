//
//  GestureRecorder.swift
//  GestureKit
//
//  Countdown → capture → downsample state machine. Samples the tracking
//  service at ~30 Hz during capture, stores at 12 fps. Snapshot mode captures
//  a 0.5 s window and keeps the median frame so a momentary jitter doesn't
//  become the template.
//

import Foundation
import QuartzCore

public enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case snapshot
    case threeSeconds
    case fiveSeconds

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .snapshot: return "Snapshot"
        case .threeSeconds: return "3 sec"
        case .fiveSeconds: return "5 sec"
        }
    }

    /// Length of the raw capture window in seconds.
    public var captureDuration: TimeInterval {
        switch self {
        case .snapshot: return 0.5
        case .threeSeconds: return 3
        case .fiveSeconds: return 5
        }
    }

    public var gestureType: GestureType {
        self == .snapshot ? .pose : .motion
    }
}

public struct RecordingConfig: Sendable {
    public var mode: CaptureMode
    public var handedness: Handedness
    public var orientationSensitive: Bool

    public init(mode: CaptureMode, handedness: Handedness, orientationSensitive: Bool = false) {
        self.mode = mode
        self.handedness = handedness
        self.orientationSensitive = orientationSensitive
    }
}

#if os(visionOS)
@Observable
@MainActor
public final class GestureRecorder {

    public enum Phase: Equatable {
        case idle
        case countdown(Int)              // 3, 2, 1
        case recording(progress: Double) // 0...1
        case finished
        case failed(String)
    }

    public static let storedFPS: Double = 12
    private static let captureFPS: Double = 30
    private static let countdownSeconds = 3

    public private(set) var phase: Phase = .idle
    /// Frames of the take that just finished; consumed by `takeResult()`.
    public private(set) var lastTake: GestureSample?

    private let tracking: HandTrackingService
    private var task: Task<Void, Never>?

    public init(tracking: HandTrackingService) {
        self.tracking = tracking
    }

    public func record(config: RecordingConfig) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run(config: config)
            self?.task = nil
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        lastTake = nil
    }

    /// Returns and clears the finished take.
    public func takeResult() -> GestureSample? {
        defer {
            lastTake = nil
            if phase == .finished { phase = .idle }
        }
        return lastTake
    }

    private func run(config: RecordingConfig) async {
        lastTake = nil
        do {
            for remaining in stride(from: Self.countdownSeconds, through: 1, by: -1) {
                phase = .countdown(remaining)
                try await Task.sleep(for: .seconds(1))
            }

            let duration = config.mode.captureDuration
            let interval = 1.0 / Self.captureFPS
            let start = CACurrentMediaTime()
            var raw: [GestureFrame] = []

            while true {
                let elapsed = CACurrentMediaTime() - start
                if elapsed >= duration { break }
                phase = .recording(progress: elapsed / duration)

                let left = config.handedness == .right ? nil
                    : tracking.leftAnchor.flatMap(HandPose.init(anchor:))
                let right = config.handedness == .left ? nil
                    : tracking.rightAnchor.flatMap(HandPose.init(anchor:))
                if left != nil || right != nil {
                    raw.append(GestureFrame(t: elapsed, left: left, right: right))
                }
                try await Task.sleep(for: .seconds(interval))
            }

            guard !raw.isEmpty else {
                phase = .failed("No tracked hands during capture. Keep hands visible and try again.")
                return
            }
            if config.handedness == .bimanual {
                raw = raw.filter { $0.left != nil && $0.right != nil }
                guard !raw.isEmpty else {
                    phase = .failed("Bimanual gesture needs both hands tracked. Try again.")
                    return
                }
            }

            let frames: [GestureFrame]
            if config.mode == .snapshot {
                frames = [Self.medianFrame(of: raw)]
            } else {
                frames = Self.downsample(raw, to: Self.storedFPS)
            }
            lastTake = GestureSample(frames: frames)
            phase = .finished
        } catch {
            phase = .idle // cancelled
        }
    }

    /// Middle frame of the window, re-timed to t=0.
    private static func medianFrame(of frames: [GestureFrame]) -> GestureFrame {
        var f = frames[frames.count / 2]
        f.t = 0
        return f
    }

    private static func downsample(_ frames: [GestureFrame], to fps: Double) -> [GestureFrame] {
        guard let last = frames.last, last.t > 0 else { return frames }
        let step = 1.0 / fps
        var result: [GestureFrame] = []
        var nextT = 0.0
        for frame in frames where frame.t >= nextT {
            var f = frame
            f.t = nextT
            result.append(f)
            nextT += step
        }
        return result
    }
}
#endif
