# GestureCapture

A visionOS app that records hand gestures from ARKit hand tracking and exports them as
**portable `.gesture.json` files** any app can ingest — plus rendered PNG/MP4 previews
and a reusable Swift module (`GestureKit`).

This README documents everything a consuming app needs. The build plan and progress
log live in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

---

## What a gesture is (files)

Each recorded gesture is a bundle of up to three sibling files (named by UUID inside
the app's `Documents/Gestures/`; exported files may carry the gesture's name):

| File | Contents | Required? |
|---|---|---|
| `<name>.gesture.json` | The gesture itself: metadata + joint data (spec below) | yes |
| `<name>.png` | Rendered thumbnail (720×720, rendered from the rigged hand model) | optional |
| `<name>.mp4` | Rendered replay video, motions only (H.264, 30 fps, 720×720) | optional |

Only the JSON is needed to *recognize or replay* a gesture. The PNG/MP4 are for UI.

---

## `.gesture.json` format (formatVersion 1)

Top-level object (keys are alphabetically sorted; dates are ISO-8601):

```jsonc
{
  "formatVersion": 1,
  "id": "9B2C1B4E-...-D2",            // UUID, stable identity of the gesture
  "name": "Thumbs Up",
  "type": "pose",                      // "pose" (1 frame) | "motion" (time series)
  "handedness": "either",              // "either" | "left" | "right" | "bimanual"
  "orientationSensitive": false,       // true → palm direction matters for matching
  "sampleRate": 12,                    // frames per second for "motion" recordings
  "createdAt": "2026-07-07T14:23:05Z",
  "device": "Apple Vision Pro",
  "coordinateSystem": {                // self-description, always the same in v1
    "units": "meters",
    "axes": "right-handed, Y-up, joints are wrist-relative; wristTransform is world (column-major 4x4)",
    "rotationFormat": "quaternion xyzw"
  },
  "jointOrder": [ /* 25 joint names, see below */ ],
  "samples": [                         // one entry per recorded take (≥ 1)
    {
      "frames": [                      // poses: exactly 1 frame; motions: n frames
        {
          "t": 0.0,                    // seconds from the start of the take
          "left":  { /* HandPose, see below — present if the left hand was captured */ },
          "right": { /* HandPose — present if the right hand was captured */ }
        }
      ]
    }
  ]
}
```

### HandPose (one hand in one frame)

```jsonc
{
  "wristTransform": [ /* 16 floats */ ],  // world transform of the wrist anchor,
                                          // 4×4, COLUMN-major (translation = indices 12,13,14)
  "joints": [ /* 175 floats = 25 × 7 */ ],// per joint, in jointOrder order:
                                          // px, py, pz, qx, qy, qz, qw
                                          // positions/rotations are WRIST-RELATIVE
  "tracked": [ /* 25 bools, optional */ ] // false = ARKit estimated (occluded) joint
}
```

- **Joint transforms are wrist-relative** (ARKit `anchorFromJointTransform`), so the
  hand's location in the room does not affect them. The wrist joint itself is identity.
- **`wristTransform` is world-space** so consumers can reconstruct absolute positions
  (`world = wristTransform · jointTransform`) or drive effects at the hand's location.
- ARKit's world origin is on the floor beneath the user at session start — useful for
  reconstructing the user's viewpoint (head ≈ `(0, 1.55, 0)`).
- ARKit joint-frame convention: **+X points along the bone toward the fingertip.**

### Joint order (25 joints)

`jointOrder` is written into every file; always index joints through it (or by name),
never by assumption. Canonical v1 order:

```
wrist,
thumbMetacarpal,  thumbProximal,  thumbDistal,  thumbTip,
indexMetacarpal,  indexProximal,  indexIntermediate,  indexDistal,  indexTip,
middleMetacarpal, middleProximal, middleIntermediate, middleDistal, middleTip,
ringMetacarpal,   ringProximal,   ringIntermediate,   ringDistal,   ringTip,
littleMetacarpal, littleProximal, littleIntermediate, littleDistal, littleTip
```

Hierarchy: every `*Metacarpal` parents to `wrist`; each finger chains
metacarpal → proximal → (intermediate →) distal → tip (the thumb has no intermediate).
This is ARKit's `HandSkeleton` minus the two forearm joints.

### Handedness semantics

- `left` / `right` — recorded from that hand; match that hand.
- `either` — recorded from one hand but intended to match both (matching should use
  chirality-invariant features; see below).
- `bimanual` — frames contain **both** `left` and `right`; the gesture includes the
  hands' relationship (compute the inter-hand transform from the two `wristTransform`s).

---

## Ingesting the JSON

### Python (analysis / non-Apple engines)

```python
import json, numpy as np

g = json.load(open("ThumbsUp.gesture.json"))
order = g["jointOrder"]
frame = g["samples"][0]["frames"][0]
hand  = frame.get("left") or frame.get("right")

J = np.array(hand["joints"]).reshape(len(order), 7)   # rows: px py pz qx qy qz qw
pos = {name: J[i, :3] for i, name in enumerate(order)}          # wrist-relative, meters
wrist_world = np.array(hand["wristTransform"]).reshape(4, 4).T  # column-major → row-major

# absolute position of the index fingertip:
tip = wrist_world @ np.append(pos["indexTip"], 1.0)
```

### Swift (with GestureKit)

The `GestureKit` sources in [GestureCapture/GestureKit/](GestureCapture/GestureKit/)
are app-independent (SPM extraction is planned; the root [Package.swift](Package.swift)
already builds them as a library for macOS tooling). Consumers get the full pipeline:

```swift
// Load
let gesture = try GestureFile.decode(from: Data(contentsOf: url))

// Recognize (inside an ImmersiveSpace with hand-tracking permission)
let tracking = HandTrackingService()          // wraps ARKitSession + HandTrackingProvider
let engine = GestureRecognitionEngine()
engine.load(gestures: [gesture])
engine.onEvent = { event in
    // event.kind (.began / .ended), event.gestureName, event.confidence
}
// feed frames ~30 Hz:
let frame = GestureFrame(t: 0,
                         left: tracking.leftAnchor.flatMap(HandPose.init(anchor:)),
                         right: tracking.rightAnchor.flatMap(HandPose.init(anchor:)))
engine.process(frame: frame)

// Replay / render on the rigged hand models
let replayer = GestureReplayer()
try await replayer.load(gesture: gesture, placement: placementMatrix)
replayer.play()
```

**Platform requirement:** raw hand-tracking data on visionOS is only available inside
an `ImmersiveSpace` (any style, `.mixed` included) and requires the
`NSHandsTrackingUsageDescription` permission. Plain Shared-Space window apps cannot
receive hand data — this applies to every consuming app.

### Writing your own matcher (any language)

The approach GestureKit uses, reproducible from the JSON alone:

1. **Features per hand** (scale/position/rotation-invariant): 5 finger curls (summed
   bend angles along each chain, normalized by π), 4 adjacent-finger splay angles,
   4 thumb-tip→fingertip distances (divided by wrist→middleProximal length, capped).
   For `orientationSensitive`, append the world-space palm normal. For `bimanual`,
   concatenate both hands + the right wrist's position/facing in the left wrist frame.
2. **Poses:** distance from the live feature vector to each take's vector; trigger
   with hysteresis (enter < 0.10, exit > 0.16 RMS in v1) plus a ~200 ms hold.
3. **Motions:** resample the take's feature trajectory to 32 frames; segment the live
   stream by motion energy (start > 0.25 m/s, end < 0.12 m/s mean wrist+fingertip
   speed); compare with DTW, path-length normalized (match < 0.09 in v1).

---

## Rigged hand models

[`_resources/3DModels/LeftHand_rigged.usdz` / `RightHand_rigged.usdz`](_resources/3DModels/) —
skinned hand meshes (1,360 verts) with a proper wrist-rooted skeleton, Y-up, meters,
`usdchecker`-clean. Bone names are snake_case (`index_finger_phalanx_proximal`, thumb
has no intermediate, little finger is `pinky_finger_*`); map to JSON joints **by name**
(the two files list joints in different orders).

⚠️ Rig frame convention differs from ARKit: the rig's bones point **−Z** along the
bone, ARKit points **+X**. Driving the rig directly with recorded rotations produces a
rest-pose hand. `RiggedHandEntity` solves the per-joint conversion at runtime from the
recording's own bone directions (see its file header for the math) — port that if you
retarget in another engine, or re-derive: rig frame = ARKit frame · Q per joint.

## Local tooling (no headset needed)

`swift run RetargetLab _captures/<file>.gesture.json <outDir>` renders any recording
to PNG (+ MP4 for motions) on macOS and prints joint-position error diagnostics —
useful for validating files you generate or transform.

## Versioning

Consumers should check `formatVersion` and reject files with a higher major version.
v1 files are self-describing: joint order, units, and axis conventions are inside the
file, so a compliant reader needs no out-of-band knowledge.
