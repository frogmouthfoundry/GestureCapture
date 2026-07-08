//
//  HandSkeletonOverlay.swift
//  GestureKit
//
//  Live debug overlay: a sphere per joint and a thin capsule per bone,
//  driven directly from HandAnchor world transforms. Untracked joints dim.
//

#if os(visionOS)
import ARKit
import RealityKit
import UIKit

@MainActor
public final class HandSkeletonOverlay {

    public let root = Entity()

    private var jointSpheres: [HandJoint: ModelEntity] = [:]
    private var bones: [HandJoint: ModelEntity] = [:]   // keyed by child joint
    private let trackedMaterial = UnlitMaterial(color: UIColor.systemGreen)
    private let untrackedMaterial = UnlitMaterial(color: UIColor.systemGray.withAlphaComponent(0.4))

    public init() {
        let sphereMesh = MeshResource.generateSphere(radius: 0.005)
        let boneMesh = MeshResource.generateCylinder(height: 1, radius: 0.002)
        for joint in HandJoint.allCases {
            let sphere = ModelEntity(mesh: sphereMesh, materials: [trackedMaterial])
            jointSpheres[joint] = sphere
            root.addChild(sphere)
            if joint.parent != nil {
                let bone = ModelEntity(mesh: boneMesh, materials: [trackedMaterial])
                bones[joint] = bone
                root.addChild(bone)
            }
        }
        root.isEnabled = false
    }

    public func update(anchor: HandAnchor?) {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else {
            root.isEnabled = false
            return
        }
        root.isEnabled = true
        let world = anchor.originFromAnchorTransform

        var positions: [HandJoint: SIMD3<Float>] = [:]
        for joint in HandJoint.allCases {
            let arkitJoint = skeleton.joint(joint.arkitName)
            let m = world * arkitJoint.anchorFromJointTransform
            let p = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            positions[joint] = p
            let sphere = jointSpheres[joint]!
            sphere.position = p
            sphere.model?.materials = [arkitJoint.isTracked ? trackedMaterial : untrackedMaterial]
        }

        for (child, bone) in bones {
            guard let a = positions[child.parent!], let b = positions[child] else { continue }
            let mid = (a + b) / 2
            let dir = b - a
            let length = simd_length(dir)
            bone.position = mid
            bone.scale = [1, max(length, 0.001), 1]
            // Cylinder's axis is +Y; rotate it onto the bone direction.
            if length > 1e-5 {
                bone.orientation = simd_quatf(from: [0, 1, 0], to: dir / length)
            }
        }
    }
}
#endif
