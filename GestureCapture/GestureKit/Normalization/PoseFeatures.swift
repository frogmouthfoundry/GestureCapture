//
//  PoseFeatures.swift
//  GestureKit
//
//  Reduces a HandPose to a small scale- and chirality-invariant feature
//  vector: 5 finger curls + 4 splay angles + 4 thumb-to-fingertip distances.
//  Orientation-sensitive gestures append the palm normal in world space.
//  Bimanual gestures concatenate both hands plus inter-hand features.
//

import Foundation
import simd

public struct PoseFeatures: Sendable {
    /// 13 values for one hand, 16 with orientation, 32 for bimanual.
    public var values: [Float]

    private static let jointIndex: [HandJoint: Int] = Dictionary(
        uniqueKeysWithValues: HandJoint.allCases.enumerated().map { ($1, $0) })

    private static let fingerChains: [[HandJoint]] = [
        [.thumbMetacarpal, .thumbProximal, .thumbDistal, .thumbTip],
        [.indexMetacarpal, .indexProximal, .indexIntermediate, .indexDistal, .indexTip],
        [.middleMetacarpal, .middleProximal, .middleIntermediate, .middleDistal, .middleTip],
        [.ringMetacarpal, .ringProximal, .ringIntermediate, .ringDistal, .ringTip],
        [.littleMetacarpal, .littleProximal, .littleIntermediate, .littleDistal, .littleTip],
    ]

    public init(hand: HandPose, orientationSensitive: Bool = false) {
        func pos(_ j: HandJoint) -> SIMD3<Float> { hand.position(at: Self.jointIndex[j]!) }

        // Hand-size reference for scale invariance.
        let scale = max(simd_length(pos(.middleProximal)), 0.02)

        var v: [Float] = []

        // Finger curls: summed bend angles along the chain, normalized to ~0...1.
        for chain in Self.fingerChains {
            var bend: Float = 0
            for i in 1..<(chain.count - 1) {
                let a = simd_normalize(pos(chain[i]) - pos(chain[i - 1]))
                let b = simd_normalize(pos(chain[i + 1]) - pos(chain[i]))
                bend += acos(simd_clamp(simd_dot(a, b), -1, 1))
            }
            v.append(bend / .pi)
        }

        // Splay: unsigned angle between adjacent proximal-phalanx directions.
        let phalanxDirs = Self.fingerChains.map { chain -> SIMD3<Float> in
            simd_normalize(pos(chain[2]) - pos(chain[1]))
        }
        for i in 0..<4 {
            v.append(acos(simd_clamp(simd_dot(phalanxDirs[i], phalanxDirs[i + 1]), -1, 1)) / .pi)
        }

        // Thumb-to-fingertip distances, scale-normalized and softly capped.
        let thumb = pos(.thumbTip)
        for tip in [HandJoint.indexTip, .middleTip, .ringTip, .littleTip] {
            v.append(min(simd_length(pos(tip) - thumb) / scale, 2) / 2)
        }

        if orientationSensitive {
            v.append(contentsOf: Self.worldPalmNormal(hand).asArray)
        }
        values = v
    }

    /// Bimanual: both hands' features plus inter-hand position/facing.
    public init(left: HandPose, right: HandPose, orientationSensitive: Bool = false) {
        var v = PoseFeatures(hand: left, orientationSensitive: orientationSensitive).values
        v += PoseFeatures(hand: right, orientationSensitive: orientationSensitive).values

        let lw = left.wristWorldTransform
        let rw = right.wristWorldTransform
        // Right wrist expressed in the left wrist's frame; distance capped at 1 m.
        let rel = lw.inverse * rw
        let relPos = SIMD3(rel.columns.3.x, rel.columns.3.y, rel.columns.3.z)
        v.append(min(simd_length(relPos), 1))
        v.append(contentsOf: (simd_length(relPos) > 0.001 ? simd_normalize(relPos) : .zero).asArray)
        v.append(simd_dot(Self.worldPalmNormal(left), Self.worldPalmNormal(right)))
        values = v
    }

    /// Palm normal in world space (unit vector, chirality-corrected to point out of the palm).
    static func worldPalmNormal(_ hand: HandPose) -> SIMD3<Float> {
        func pos(_ j: HandJoint) -> SIMD3<Float> { hand.position(at: jointIndex[j]!) }
        let across = pos(.littleProximal) - pos(.indexProximal)
        let along = pos(.middleProximal) // from wrist origin
        var normal = simd_cross(along, across)
        if simd_length(normal) < 1e-5 { return .zero }
        normal = simd_normalize(normal)
        let world = hand.wristWorldTransform
        let rotated = world * SIMD4(normal, 0)
        return SIMD3(rotated.x, rotated.y, rotated.z)
    }

    public static func distance(_ a: PoseFeatures, _ b: PoseFeatures) -> Float {
        guard a.values.count == b.values.count, !a.values.isEmpty else { return .infinity }
        var sum: Float = 0
        for i in 0..<a.values.count {
            let d = a.values[i] - b.values[i]
            sum += d * d
        }
        return sqrt(sum / Float(a.values.count))
    }

    public static func average(_ items: [PoseFeatures]) -> PoseFeatures? {
        guard let first = items.first,
              items.allSatisfy({ $0.values.count == first.values.count }) else { return nil }
        var sum = [Float](repeating: 0, count: first.values.count)
        for item in items {
            for i in 0..<sum.count { sum[i] += item.values[i] }
        }
        var result = first
        result.values = sum.map { $0 / Float(items.count) }
        return result
    }
}

extension SIMD3<Float> {
    var asArray: [Float] { [x, y, z] }
}

public extension GestureFrame {
    /// Features for this frame under the gesture's handedness rule, or nil if
    /// the required hands aren't present.
    func features(handedness: Handedness, orientationSensitive: Bool) -> PoseFeatures? {
        switch handedness {
        case .bimanual:
            guard let l = left, let r = right else { return nil }
            return PoseFeatures(left: l, right: r, orientationSensitive: orientationSensitive)
        case .left:
            return left.map { PoseFeatures(hand: $0, orientationSensitive: orientationSensitive) }
        case .right:
            return right.map { PoseFeatures(hand: $0, orientationSensitive: orientationSensitive) }
        case .either:
            // Features are chirality-invariant; prefer whichever hand is present.
            let hand = right ?? left
            return hand.map { PoseFeatures(hand: $0, orientationSensitive: orientationSensitive) }
        }
    }
}
