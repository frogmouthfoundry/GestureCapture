//
//  RetargetLab — macOS diagnostic for the rigged-hand retargeting path.
//
//  Usage: swift run RetargetLab [gesture.json] [outDir]
//  Loads the recorded gesture, applies it to the rig exactly like the app does,
//  prints forward-kinematics error vs. the recorded joint positions, and renders
//  a PNG from the same GesturePreviewRenderer the app uses.
//

import Foundation
import GestureKit
import RealityKit
import simd

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let args = CommandLine.arguments
let jsonPath = args.count > 1 ? args[1] : "_captures/Thumbsup-Left.gesture.json"
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "Tools/RetargetLab/out")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

RiggedHandEntity.resourceURL = { name in
    repoRoot.appending(path: "_resources/3DModels/\(name).usdz")
}

let gesture = try GestureFile.decode(from: Data(contentsOf: repoRoot.appending(path: jsonPath)))
print("Loaded '\(gesture.name)' type=\(gesture.type.rawValue) handedness=\(gesture.handedness.rawValue)")

guard let frame = gesture.samples.first?.frames.first,
      let pose = frame.left ?? frame.right else {
    fatalError("No hand data in first frame")
}
let chirality: Handedness = frame.left != nil ? .left : .right

// --- Apply + FK diagnostics ---------------------------------------------------

let hand = try await RiggedHandEntity(chirality: chirality)
hand.apply(pose: pose, worldPlacement: matrix_identity_float4x4)

let model = hand.model
let names = model.jointNames
let transforms = model.jointTransforms

// Parent index from joint paths ("wrist/thumb_metacarpal/..." → drop last component).
func parentIndex(of path: String) -> Int? {
    guard let slash = path.lastIndex(of: "/") else { return nil }
    let parentPath = String(path[..<slash])
    return names.firstIndex(of: parentPath)
}

// FK: model-space transform per rig joint.
var modelSpace = [simd_float4x4](repeating: matrix_identity_float4x4, count: names.count)
for i in names.indices {
    let local = transforms[i].matrix
    if let p = parentIndex(of: names[i]) {
        modelSpace[i] = modelSpace[p] * local
    } else {
        modelSpace[i] = local
    }
}

// Compare achieved wrist-relative joint positions with the recorded ones.
let order = HandJoint.allCases
guard let wristRigIdx = names.firstIndex(where: { $0.hasSuffix("wrist") }) else {
    fatalError("no wrist joint in rig")
}
let wristInv = modelSpace[wristRigIdx].inverse
// Achieved positions live in the rig's wrist frame; recorded live in ARKit's.
// Convert via Q_wrist (rig frame = ARKit frame · Q).
let qWrist = hand.wristCalibration ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
print("\nFK check (ARKit wrist frame, meters): recorded → achieved | error")
var worst: Float = 0
for (i, joint) in order.enumerated() {
    guard let rigIdx = names.firstIndex(where: {
        $0 == joint.rigBoneName || $0.hasSuffix("/" + joint.rigBoneName)
    }) else { continue }
    let achieved4 = (wristInv * modelSpace[rigIdx]).columns.3
    let achieved = qWrist.act(SIMD3(achieved4.x, achieved4.y, achieved4.z))
    let recorded = pose.position(at: i)
    let err = simd_length(achieved - recorded)
    worst = max(worst, err)
    if err > 0.01 {
        print(String(format: "  %@ rec(%.3f %.3f %.3f) got(%.3f %.3f %.3f) err %.1f mm",
                     joint.rawValue, recorded.x, recorded.y, recorded.z,
                     achieved.x, achieved.y, achieved.z, err * 1000))
    }
}
print(String(format: "worst joint position error: %.1f mm (model-vs-user proportions account for ~10-20)",
             worst * 1000))

// --- Render PNG via the app's preview renderer --------------------------------

let renderer = try GesturePreviewRenderer()
let output = try await renderer.render(
    gesture: gesture, videoDestination: outDir.appending(path: "replay.mp4"))
let pngURL = outDir.appending(path: "thumbnail.png")
try output.thumbnailPNG.write(to: pngURL)
print("\nWrote \(pngURL.path)")
