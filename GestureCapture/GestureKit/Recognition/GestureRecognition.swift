//
//  GestureRecognition.swift
//  GestureKit
//
//  Template-based recognition, no ML.
//  - Poses: feature distance with hysteresis (tight enter / loose exit) and a
//    hold time so flicker never triggers.
//  - Motions: motion-energy segmentation of the live stream, then DTW against
//    templates resampled to a fixed length. DTW absorbs speed differences.
//

import Foundation
import QuartzCore
import simd

public struct GestureEvent: Sendable {
    public enum Kind: Sendable { case began, ended }
    public var kind: Kind
    public var gestureID: UUID
    public var gestureName: String
    public var confidence: Float   // 0...1
    public var timestamp: TimeInterval
}

/// Live per-gesture confidence for UI meters. 1 = perfect match.
public struct GestureConfidence: Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var confidence: Float
    public var isActive: Bool
}

// MARK: - Pose matching

struct PoseTemplate {
    let id: UUID
    let name: String
    let handedness: Handedness
    let orientationSensitive: Bool
    let features: [PoseFeatures]   // one per recorded take

    func distance(to live: PoseFeatures) -> Float {
        features.map { PoseFeatures.distance($0, live) }.min() ?? .infinity
    }
}

final class PoseMatcher {
    // Tuned for the 13/16/32-dim normalized feature space.
    static let enterDistance: Float = 0.10
    static let exitDistance: Float = 0.16
    static let holdSeconds: TimeInterval = 0.2

    let template: PoseTemplate
    private var candidateSince: TimeInterval?
    private(set) var isActive = false
    private(set) var lastConfidence: Float = 0

    init(template: PoseTemplate) { self.template = template }

    /// Returns an event when the pose begins or ends.
    func update(frame: GestureFrame, at time: TimeInterval) -> GestureEvent? {
        guard let live = frame.features(handedness: template.handedness,
                                        orientationSensitive: template.orientationSensitive) else {
            lastConfidence = 0
            candidateSince = nil
            return deactivateIfNeeded(at: time)
        }
        let d = template.distance(to: live)
        lastConfidence = max(0, 1 - d / (Self.exitDistance * 2))

        if isActive {
            if d > Self.exitDistance { return deactivateIfNeeded(at: time) }
            return nil
        }
        if d < Self.enterDistance {
            if let since = candidateSince {
                if time - since >= Self.holdSeconds {
                    isActive = true
                    candidateSince = nil
                    return GestureEvent(kind: .began, gestureID: template.id,
                                        gestureName: template.name,
                                        confidence: lastConfidence, timestamp: time)
                }
            } else {
                candidateSince = time
            }
        } else {
            candidateSince = nil
        }
        return nil
    }

    private func deactivateIfNeeded(at time: TimeInterval) -> GestureEvent? {
        guard isActive else { return nil }
        isActive = false
        return GestureEvent(kind: .ended, gestureID: template.id,
                            gestureName: template.name,
                            confidence: lastConfidence, timestamp: time)
    }
}

// MARK: - Motion matching (DTW)

struct MotionTemplate {
    static let resampleCount = 32

    let id: UUID
    let name: String
    let handedness: Handedness
    let orientationSensitive: Bool
    let trajectories: [[PoseFeatures]]  // one resampled trajectory per take

    static func resample(_ features: [PoseFeatures], to count: Int) -> [PoseFeatures] {
        guard features.count > 1 else { return features }
        return (0..<count).map { i in
            let x = Double(i) / Double(count - 1) * Double(features.count - 1)
            return features[Int(x.rounded())]
        }
    }

    static func dtwDistance(_ a: [PoseFeatures], _ b: [PoseFeatures]) -> Float {
        guard !a.isEmpty, !b.isEmpty else { return .infinity }
        let n = a.count, m = b.count
        var prev = [Float](repeating: .infinity, count: m + 1)
        var curr = prev
        prev[0] = 0
        for i in 1...n {
            curr = [Float](repeating: .infinity, count: m + 1)
            for j in 1...m {
                let cost = PoseFeatures.distance(a[i - 1], b[j - 1])
                curr[j] = cost + min(prev[j], curr[j - 1], prev[j - 1])
            }
            prev = curr
        }
        return prev[m] / Float(n + m)  // path-length normalized
    }

    func distance(to segment: [PoseFeatures]) -> Float {
        let live = Self.resample(segment, to: Self.resampleCount)
        return trajectories.map { Self.dtwDistance($0, live) }.min() ?? .infinity
    }
}

final class MotionMatcher {
    static let matchDistance: Float = 0.09

    let template: MotionTemplate
    private(set) var lastConfidence: Float = 0

    init(template: MotionTemplate) { self.template = template }

    /// Scores a finished live segment; emits began+ended as one pair on match.
    func score(segment: [PoseFeatures], at time: TimeInterval) -> [GestureEvent] {
        let d = template.distance(to: segment)
        lastConfidence = max(0, 1 - d / (Self.matchDistance * 2))
        guard d < Self.matchDistance else { return [] }
        return [
            GestureEvent(kind: .began, gestureID: template.id, gestureName: template.name,
                         confidence: lastConfidence, timestamp: time),
            GestureEvent(kind: .ended, gestureID: template.id, gestureName: template.name,
                         confidence: lastConfidence, timestamp: time),
        ]
    }
}

// MARK: - Engine

/// Feed live frames at any steady rate (~30 Hz recommended); emits events and
/// keeps per-gesture confidences for UI.
@Observable
@MainActor
public final class GestureRecognitionEngine {

    public var onEvent: (@MainActor (GestureEvent) -> Void)?
    public private(set) var confidences: [GestureConfidence] = []

    private var poseMatchers: [PoseMatcher] = []
    private var motionMatchers: [MotionMatcher] = []

    // Live segmentation state for motions.
    private struct LiveFrame {
        let time: TimeInterval
        let frame: GestureFrame
        let energy: Float
    }
    private var window: [LiveFrame] = []
    private var segmentStart: TimeInterval?
    private var stillSince: TimeInterval?
    private var lastPositions: [SIMD3<Float>]?

    private static let startEnergy: Float = 0.25   // m/s, mean fingertip+wrist speed
    private static let endEnergy: Float = 0.12
    private static let endStillSeconds: TimeInterval = 0.3
    private static let maxSegmentSeconds: TimeInterval = 6

    public init() {}

    public func load(gestures: [GestureFile]) {
        poseMatchers = []
        motionMatchers = []
        for g in gestures {
            switch g.type {
            case .pose:
                let feats = g.samples.compactMap {
                    $0.frames.first?.features(handedness: g.handedness,
                                              orientationSensitive: g.orientationSensitive)
                }
                guard !feats.isEmpty else { continue }
                poseMatchers.append(PoseMatcher(template: PoseTemplate(
                    id: g.id, name: g.name, handedness: g.handedness,
                    orientationSensitive: g.orientationSensitive, features: feats)))
            case .motion:
                let trajectories = g.samples.compactMap { sample -> [PoseFeatures]? in
                    let feats = sample.frames.compactMap {
                        $0.features(handedness: g.handedness,
                                    orientationSensitive: g.orientationSensitive)
                    }
                    guard feats.count > 1 else { return nil }
                    return MotionTemplate.resample(feats, to: MotionTemplate.resampleCount)
                }
                guard !trajectories.isEmpty else { continue }
                motionMatchers.append(MotionMatcher(template: MotionTemplate(
                    id: g.id, name: g.name, handedness: g.handedness,
                    orientationSensitive: g.orientationSensitive, trajectories: trajectories)))
            }
        }
        confidences = []
    }

    public func process(frame: GestureFrame) {
        let now = CACurrentMediaTime()
        var events: [GestureEvent] = []

        for matcher in poseMatchers {
            if let e = matcher.update(frame: frame, at: now) { events.append(e) }
        }

        if !motionMatchers.isEmpty {
            events += processMotion(frame: frame, at: now)
        }

        confidences = poseMatchers.map {
            GestureConfidence(id: $0.template.id, name: $0.template.name,
                              confidence: $0.lastConfidence, isActive: $0.isActive)
        } + motionMatchers.map {
            GestureConfidence(id: $0.template.id, name: $0.template.name,
                              confidence: $0.lastConfidence, isActive: false)
        }

        for e in events { onEvent?(e) }
    }

    private func processMotion(frame: GestureFrame, at now: TimeInterval) -> [GestureEvent] {
        // Motion energy: mean speed of wrist + fingertips across tracked hands.
        var positions: [SIMD3<Float>] = []
        for hand in [frame.left, frame.right].compactMap({ $0 }) {
            let world = hand.wristWorldTransform
            positions.append(SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z))
            for tip in HandJoint.fingertips {
                let idx = HandJoint.allCases.firstIndex(of: tip)!
                let local = hand.position(at: idx)
                let w = world * SIMD4(local, 1)
                positions.append(SIMD3(w.x, w.y, w.z))
            }
        }
        defer { lastPositions = positions }

        var energy: Float = 0
        if let prev = lastPositions, prev.count == positions.count, !positions.isEmpty,
           let dt = window.last.map({ now - $0.time }), dt > 0 {
            let mean = zip(prev, positions).map { simd_length($1 - $0) }.reduce(0, +) / Float(positions.count)
            energy = mean / Float(dt)
        }
        window.append(LiveFrame(time: now, frame: frame, energy: energy))
        window.removeAll { now - $0.time > Self.maxSegmentSeconds + 1 }

        if segmentStart == nil {
            if energy > Self.startEnergy {
                // Back up slightly so the segment includes the motion onset.
                segmentStart = now - 0.15
                stillSince = nil
            }
            return []
        }

        if energy < Self.endEnergy {
            if stillSince == nil { stillSince = now }
        } else {
            stillSince = nil
        }

        let timedOut = now - segmentStart! > Self.maxSegmentSeconds
        guard timedOut || (stillSince != nil && now - stillSince! >= Self.endStillSeconds) else {
            return []
        }

        let start = segmentStart!
        let end = stillSince ?? now
        segmentStart = nil
        stillSince = nil

        let segmentFrames = window.filter { $0.time >= start && $0.time <= end }.map(\.frame)
        guard segmentFrames.count > 3 else { return [] }

        var events: [GestureEvent] = []
        for matcher in motionMatchers {
            let feats = segmentFrames.compactMap {
                $0.features(handedness: matcher.template.handedness,
                            orientationSensitive: matcher.template.orientationSensitive)
            }
            guard feats.count > 3 else { continue }
            events += matcher.score(segment: feats, at: now)
        }
        return events
    }
}
