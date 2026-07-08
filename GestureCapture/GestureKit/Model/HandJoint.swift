//
//  HandJoint.swift
//  GestureKit
//
//  Canonical 25-joint hand skeleton: ARKit's HandSkeleton minus the two
//  forearm joints. All storage, features, and retargeting use this order.
//  Joint identity across systems (ARKit / USD rig / JSON) is always by name.
//

#if os(visionOS)
import ARKit
#endif

public enum HandJoint: String, CaseIterable, Codable, Sendable {
    case wrist

    case thumbMetacarpal, thumbProximal, thumbDistal, thumbTip

    case indexMetacarpal, indexProximal, indexIntermediate, indexDistal, indexTip
    case middleMetacarpal, middleProximal, middleIntermediate, middleDistal, middleTip
    case ringMetacarpal, ringProximal, ringIntermediate, ringDistal, ringTip
    case littleMetacarpal, littleProximal, littleIntermediate, littleDistal, littleTip

    /// Parent joint in the kinematic chain; nil for the wrist root.
    public var parent: HandJoint? {
        switch self {
        case .wrist: return nil
        case .thumbMetacarpal, .indexMetacarpal, .middleMetacarpal,
             .ringMetacarpal, .littleMetacarpal:
            return .wrist
        case .thumbProximal: return .thumbMetacarpal
        case .thumbDistal: return .thumbProximal
        case .thumbTip: return .thumbDistal
        case .indexProximal: return .indexMetacarpal
        case .indexIntermediate: return .indexProximal
        case .indexDistal: return .indexIntermediate
        case .indexTip: return .indexDistal
        case .middleProximal: return .middleMetacarpal
        case .middleIntermediate: return .middleProximal
        case .middleDistal: return .middleIntermediate
        case .middleTip: return .middleDistal
        case .ringProximal: return .ringMetacarpal
        case .ringIntermediate: return .ringProximal
        case .ringDistal: return .ringIntermediate
        case .ringTip: return .ringDistal
        case .littleProximal: return .littleMetacarpal
        case .littleIntermediate: return .littleProximal
        case .littleDistal: return .littleIntermediate
        case .littleTip: return .littleDistal
        }
    }

#if os(visionOS)
    /// Matching joint in ARKit's HandSkeleton.
    public var arkitName: HandSkeleton.JointName {
        switch self {
        case .wrist: return .wrist
        case .thumbMetacarpal: return .thumbKnuckle
        case .thumbProximal: return .thumbIntermediateBase
        case .thumbDistal: return .thumbIntermediateTip
        case .thumbTip: return .thumbTip
        case .indexMetacarpal: return .indexFingerMetacarpal
        case .indexProximal: return .indexFingerKnuckle
        case .indexIntermediate: return .indexFingerIntermediateBase
        case .indexDistal: return .indexFingerIntermediateTip
        case .indexTip: return .indexFingerTip
        case .middleMetacarpal: return .middleFingerMetacarpal
        case .middleProximal: return .middleFingerKnuckle
        case .middleIntermediate: return .middleFingerIntermediateBase
        case .middleDistal: return .middleFingerIntermediateTip
        case .middleTip: return .middleFingerTip
        case .ringMetacarpal: return .ringFingerMetacarpal
        case .ringProximal: return .ringFingerKnuckle
        case .ringIntermediate: return .ringFingerIntermediateBase
        case .ringDistal: return .ringFingerIntermediateTip
        case .ringTip: return .ringFingerTip
        case .littleMetacarpal: return .littleFingerMetacarpal
        case .littleProximal: return .littleFingerKnuckle
        case .littleIntermediate: return .littleFingerIntermediateBase
        case .littleDistal: return .littleFingerIntermediateTip
        case .littleTip: return .littleFingerTip
        }
    }
#endif

    /// Bone name inside LeftHand_rigged.usdz / RightHand_rigged.usdz.
    public var rigBoneName: String {
        switch self {
        case .wrist: return "wrist"
        case .thumbMetacarpal: return "thumb_metacarpal"
        case .thumbProximal: return "thumb_phalanx_proximal"
        case .thumbDistal: return "thumb_phalanx_distal"
        case .thumbTip: return "thumb_tip"
        case .indexMetacarpal: return "index_finger_metacarpal"
        case .indexProximal: return "index_finger_phalanx_proximal"
        case .indexIntermediate: return "index_finger_phalanx_intermediate"
        case .indexDistal: return "index_finger_phalanx_distal"
        case .indexTip: return "index_finger_tip"
        case .middleMetacarpal: return "middle_finger_metacarpal"
        case .middleProximal: return "middle_finger_phalanx_proximal"
        case .middleIntermediate: return "middle_finger_phalanx_intermediate"
        case .middleDistal: return "middle_finger_phalanx_distal"
        case .middleTip: return "middle_finger_tip"
        case .ringMetacarpal: return "ring_finger_metacarpal"
        case .ringProximal: return "ring_finger_phalanx_proximal"
        case .ringIntermediate: return "ring_finger_phalanx_intermediate"
        case .ringDistal: return "ring_finger_phalanx_distal"
        case .ringTip: return "ring_finger_tip"
        case .littleMetacarpal: return "pinky_finger_metacarpal"
        case .littleProximal: return "pinky_finger_phalanx_proximal"
        case .littleIntermediate: return "pinky_finger_phalanx_intermediate"
        case .littleDistal: return "pinky_finger_phalanx_distal"
        case .littleTip: return "pinky_finger_tip"
        }
    }

    public static let fingertips: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
}
