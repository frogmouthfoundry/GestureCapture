//
//  GestureReplayer.swift
//  GestureKit
//
//  Plays a recorded gesture on rigged hand entities: looping ghost replay in
//  the immersive space, scrubbing, and frame-exact stepping for offscreen
//  rendering. Frames are interpolated between stored 12 fps samples.
//

import Foundation
import RealityKit
import simd

@Observable
@MainActor
public final class GestureReplayer {

    public let root = Entity()
    public private(set) var duration: TimeInterval = 0
    public var isLooping = true
    public private(set) var isPlaying = false
    /// 0...duration, observable for scrub UI.
    public private(set) var playhead: TimeInterval = 0

    private var frames: [GestureFrame] = []
    private var leftHand: RiggedHandEntity?
    private var rightHand: RiggedHandEntity?
    private var playTask: Task<Void, Never>?
    /// Recorded wrist frames are re-based so the replay floats at this transform.
    private var placement: simd_float4x4 = matrix_identity_float4x4
    private var baseWrist: simd_float4x4 = matrix_identity_float4x4

    public init() {}

    /// Loads the sample and prepares rig entities for whichever hands it contains.
    public func load(gesture: GestureFile, sampleIndex: Int = 0, placement: simd_float4x4) async throws {
        stop()
        root.children.forEach { $0.removeFromParent() }
        leftHand = nil
        rightHand = nil

        guard gesture.samples.indices.contains(sampleIndex) else { return }
        frames = gesture.samples[sampleIndex].frames
        duration = frames.last?.t ?? 0
        self.placement = placement

        // Re-base on the first frame's dominant wrist POSITION so replays float
        // at the placement point — but keep the recorded orientation, so a
        // thumbs-up still points up.
        if let first = frames.first,
           let wrist = (first.right ?? first.left)?.wristWorldTransform {
            baseWrist = matrix_identity_float4x4
            baseWrist.columns.3 = wrist.columns.3
        }

        if frames.contains(where: { $0.left != nil }) {
            let hand = try await RiggedHandEntity(chirality: .left)
            root.addChild(hand.root)
            leftHand = hand
        }
        if frames.contains(where: { $0.right != nil }) {
            let hand = try await RiggedHandEntity(chirality: .right)
            root.addChild(hand.root)
            rightHand = hand
        }
        seek(to: 0)
    }

    public func play() {
        guard !isPlaying, !frames.isEmpty else { return }
        isPlaying = true
        playTask = Task { [weak self] in
            let step = 1.0 / 30.0
            while let self, !Task.isCancelled, self.isPlaying {
                var next = self.playhead + step
                if next > self.duration {
                    if self.isLooping { next = 0 } else {
                        self.seek(to: self.duration)
                        self.isPlaying = false
                        break
                    }
                }
                self.seek(to: next)
                try? await Task.sleep(for: .seconds(step))
            }
        }
    }

    public func pause() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    public func stop() {
        pause()
        playhead = 0
    }

    public func seek(to time: TimeInterval) {
        playhead = min(max(time, 0), duration)
        guard let frame = interpolatedFrame(at: playhead) else { return }
        if let pose = frame.left, let hand = leftHand {
            hand.apply(pose: pose, worldPlacement: rebased(pose.wristWorldTransform))
        }
        if let pose = frame.right, let hand = rightHand {
            hand.apply(pose: pose, worldPlacement: rebased(pose.wristWorldTransform))
        }
    }

    /// Recorded wrist world → replay-space: placement · baseWrist⁻¹ · recorded.
    private func rebased(_ recordedWrist: simd_float4x4) -> simd_float4x4 {
        placement * baseWrist.inverse * recordedWrist
    }

    private func interpolatedFrame(at time: TimeInterval) -> GestureFrame? {
        guard !frames.isEmpty else { return nil }
        guard frames.count > 1 else { return frames[0] }
        guard let upper = frames.firstIndex(where: { $0.t >= time }) else { return frames.last }
        guard upper > 0 else { return frames[0] }
        let a = frames[upper - 1], b = frames[upper]
        let span = b.t - a.t
        guard span > 0 else { return b }
        let f = Float((time - a.t) / span)
        return GestureFrame(t: time,
                            left: HandPose.lerp(a.left, b.left, f),
                            right: HandPose.lerp(a.right, b.right, f))
    }
}

extension HandPose {
    /// Component-wise interpolation: positions lerped, rotations slerped.
    static func lerp(_ a: HandPose?, _ b: HandPose?, _ f: Float) -> HandPose? {
        guard let a else { return b }
        guard let b, b.joints.count == a.joints.count else { return a }

        let wa = a.wristWorldTransform, wb = b.wristWorldTransform
        let wRot = simd_slerp(simd_quatf(wa), simd_quatf(wb), f)
        let wPos = simd_mix(wa.columns.3, wb.columns.3, SIMD4(repeating: f))
        var wrist = simd_float4x4(wRot)
        wrist.columns.3 = wPos

        let count = a.joints.count / stridePerJoint
        var transforms: [simd_float4x4] = []
        transforms.reserveCapacity(count)
        for i in 0..<count {
            let rot = simd_slerp(a.rotation(at: i), b.rotation(at: i), f)
            let pos = simd_mix(a.position(at: i), b.position(at: i), SIMD3(repeating: f))
            var m = simd_float4x4(rot)
            m.columns.3 = SIMD4(pos, 1)
            transforms.append(m)
        }
        return HandPose(wristTransform: wrist, jointTransforms: transforms, tracked: nil)
    }
}
