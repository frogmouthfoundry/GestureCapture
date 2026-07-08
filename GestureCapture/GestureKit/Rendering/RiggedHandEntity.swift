//
//  RiggedHandEntity.swift
//  GestureKit
//
//  Loads LeftHand_rigged.usdz / RightHand_rigged.usdz and retargets recorded
//  HandPose data onto the rig. Joints are matched by NAME (the two files list
//  joints in different orders). The model keeps its own bone lengths, so any
//  user's recording deforms the mesh cleanly.
//
//  Frame-convention calibration: ARKit joint frames point +X along the bone;
//  this rig's frames point −Z along the bone (measured, not documented). Each
//  rig frame = ARKit frame · Q_j for a fixed per-joint rotation Q_j. Q is
//  solved at runtime from the first applied pose: a global Q via TRIAD on the
//  wrist→metacarpal fan (pose-independent — those offsets are rigid), then a
//  per-joint refinement aligning each bone axis exactly, roll from global Q.
//  Rig-local rotation = Q_parent⁻¹ · R_arkit(parentFromJoint) · Q_joint.
//

import Foundation
import RealityKit
import simd

@MainActor
public final class RiggedHandEntity {

    public let root = Entity()

    /// Override to load rig files from outside Bundle.main (tests, macOS tools).
    public nonisolated(unsafe) static var resourceURL: (String) -> URL? = { name in
        Bundle.main.url(forResource: name, withExtension: "usdz")
    }

    /// Exposed for diagnostics/tests.
    public let model: ModelEntity
    /// Canonical joint → index into model.jointTransforms.
    private let jointIndices: [HandJoint: Int]
    private let restTransforms: [Transform]
    /// Rig-root-space transform of the wrist joint at rest; used to place the
    /// entity so the wrist lands exactly on the recorded wrist world transform.
    private let restWristMatrix: simd_float4x4
    /// Per-joint frame conversion (rig frame = ARKit frame · Q), solved lazily
    /// from the first applied pose and cached.
    private var calibration: [HandJoint: simd_quatf]?

    public init(chirality: Handedness) async throws {
        let resource = chirality == .left ? "LeftHand_rigged" : "RightHand_rigged"
        guard let url = Self.resourceURL(resource) else {
            throw GestureKitError.missingResource(resource)
        }
        let loaded = try await Entity(contentsOf: url)

        guard let model = loaded.findModelWithSkeleton() else {
            throw GestureKitError.notRigged(resource)
        }
        self.model = model

        var indices: [HandJoint: Int] = [:]
        for joint in HandJoint.allCases {
            // jointNames are full paths ("wrist/index_finger_metacarpal/..."); match the leaf.
            if let idx = model.jointNames.firstIndex(where: {
                $0 == joint.rigBoneName || $0.hasSuffix("/" + joint.rigBoneName)
            }) {
                indices[joint] = idx
            }
        }
        guard indices.count == HandJoint.allCases.count else {
            throw GestureKitError.notRigged(resource)
        }
        self.jointIndices = indices
        self.restTransforms = model.jointTransforms
        self.restWristMatrix = restTransforms[indices[.wrist]!].matrix

        root.addChild(loaded)
    }

    /// Poses the rig from one recorded hand frame. `worldPlacement` overrides
    /// the recorded wrist world transform (e.g. to replay in front of the user).
    public func apply(pose: HandPose, worldPlacement: simd_float4x4? = nil) {
        let q = calibration ?? {
            let solved = Self.solveCalibration(pose: pose, restTransforms: restTransforms,
                                               jointIndices: jointIndices)
            calibration = solved
            return solved
        }()

        var transforms = model.jointTransforms
        let order = HandJoint.allCases

        for (index, joint) in order.enumerated() {
            guard let rigIndex = jointIndices[joint], let parent = joint.parent,
                  let qJoint = q[joint], let qParent = q[parent] else { continue }
            let parentIndex = order.firstIndex(of: parent)!
            // parentFromJoint = anchorFromParent⁻¹ · anchorFromJoint (ARKit frames)
            let arkitRotation = simd_quatf(pose.transform(at: parentIndex).inverse
                                           * pose.transform(at: index))
            transforms[rigIndex] = Transform(
                scale: restTransforms[rigIndex].scale,
                rotation: qParent.inverse * arkitRotation * qJoint,
                translation: restTransforms[rigIndex].translation)
        }
        model.jointTransforms = transforms

        // Place the entity so the rig's wrist frame (= ARKit wrist frame · Q_wrist)
        // coincides with the recorded wrist world transform.
        let wristWorld = worldPlacement ?? pose.wristWorldTransform
        let qWrist = simd_float4x4(q[.wrist] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        root.setTransformMatrix(wristWorld * qWrist * restWristMatrix.inverse, relativeTo: nil)
    }

    /// Wrist-relative achieved/expected conversion for diagnostics/tests.
    public var wristCalibration: simd_quatf? { calibration?[.wrist] }

    // MARK: - Calibration

    /// Solves rig-frame = ARKit-frame · Q per joint. See file header for method.
    private static func solveCalibration(pose: HandPose,
                                         restTransforms: [Transform],
                                         jointIndices: [HandJoint: Int]) -> [HandJoint: simd_quatf] {
        let order = HandJoint.allCases

        // Child offset direction in the parent's frame, for both conventions.
        func arkitDir(of joint: HandJoint) -> SIMD3<Float>? {
            guard let parent = joint.parent,
                  let ji = order.firstIndex(of: joint), let pi = order.firstIndex(of: parent) else { return nil }
            let local = pose.transform(at: pi).inverse * pose.transform(at: ji)
            let t = SIMD3(local.columns.3.x, local.columns.3.y, local.columns.3.z)
            let len = simd_length(t)
            return len > 1e-5 ? t / len : nil
        }
        func rigDir(of joint: HandJoint) -> SIMD3<Float>? {
            guard let rigIndex = jointIndices[joint] else { return nil }
            let t = restTransforms[rigIndex].translation
            let len = simd_length(t)
            return len > 1e-5 ? t / len : nil
        }

        // Global Q from the wrist→metacarpal fan via TRIAD:
        // v1 = mean fan direction, v2 = fan spread (index − little).
        let mets: [HandJoint] = [.thumbMetacarpal, .indexMetacarpal, .middleMetacarpal,
                                 .ringMetacarpal, .littleMetacarpal]
        var arkMean = SIMD3<Float>.zero, rigMean = SIMD3<Float>.zero
        for m in mets {
            arkMean += arkitDir(of: m) ?? .zero
            rigMean += rigDir(of: m) ?? .zero
        }
        let arkSpread = (arkitDir(of: .indexMetacarpal) ?? .zero) - (arkitDir(of: .littleMetacarpal) ?? .zero)
        let rigSpread = (rigDir(of: .indexMetacarpal) ?? .zero) - (rigDir(of: .littleMetacarpal) ?? .zero)

        func triad(_ v1: SIMD3<Float>, _ v2: SIMD3<Float>) -> simd_float3x3 {
            let a = simd_normalize(v1)
            let c = simd_normalize(simd_cross(v1, v2))
            return simd_float3x3(a, c, simd_cross(a, c))
        }
        // Q maps rig coords → ARKit coords: Q · d_rig = d_ark
        let globalQ = simd_quatf(triad(arkMean, arkSpread) * triad(rigMean, rigSpread).transpose)

        // Per-joint refinement: rotate globalQ minimally so this joint's bone
        // axis maps exactly; children average when a joint has several (wrist).
        var result: [HandJoint: simd_quatf] = [:]
        for joint in order {
            let children = order.filter { $0.parent == joint }
            var ark = SIMD3<Float>.zero, rig = SIMD3<Float>.zero
            for child in children {
                ark += arkitDir(of: child) ?? .zero
                rig += rigDir(of: child) ?? .zero
            }
            guard simd_length(ark) > 1e-5, simd_length(rig) > 1e-5 else {
                // Leaf joints (fingertips): inherit the parent's calibration.
                result[joint] = joint.parent.flatMap { result[$0] } ?? globalQ
                continue
            }
            let mapped = globalQ.act(simd_normalize(rig))
            let correction = simd_quatf(from: mapped, to: simd_normalize(ark))
            result[joint] = correction * globalQ
        }
        return result
    }
}

public enum GestureKitError: Error, LocalizedError {
    case missingResource(String)
    case notRigged(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "Bundle resource \(name).usdz not found."
        case .notRigged(let name): return "\(name).usdz has no matching skeleton joints."
        }
    }
}

extension Entity {
    /// Depth-first search for the first ModelEntity that carries a skeleton.
    func findModelWithSkeleton() -> ModelEntity? {
        if let model = self as? ModelEntity, !model.jointNames.isEmpty {
            return model
        }
        for child in children {
            if let found = child.findModelWithSkeleton() { return found }
        }
        return nil
    }
}
