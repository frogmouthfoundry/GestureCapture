# GestureCapture — Implementation Plan & Progress

> **Purpose of this file:** restart-safe record of all design decisions and build steps.
> If the working thread is lost, resume from the first unchecked step below.
> Update checkboxes + "Current status" as work progresses.

## Product summary

visionOS app that records hand gestures (static poses + dynamic motions, single-hand or
bimanual) from ARKit hand tracking, stores them as portable JSON (+ rendered PNG/MP4
previews), plays them back, live-tests recognition, and exposes everything through a
reusable module (`GestureKit`, extracted to SPM later) so other apps can load a
`.gesture.json` and receive recognition events.

## Locked design decisions

- **Spaces:** hand tracking requires an `ImmersiveSpace`; app uses `.mixed` immersion
  (passthrough visible). Already configured in the template. Consuming apps have the
  same requirement.
- **Recording:** capture at native ~30 Hz, **store at 12 fps**. Capture modes:
  **snapshot / 3 s / 5 s**, each preceded by a 3-2-1 countdown (no pinch to trigger —
  pinch contaminates data). Snapshot = short window averaged to 1 frame.
- **JSON format** (`.gesture.json`, formatVersion 1): meta (id, name, type pose|motion,
  handedness either|left|right|bimanual, orientationSensitive flag, sampleRate,
  coordinate conventions: meters, right-handed, Y-up), `jointOrder` array (canonical
  25-joint order, see below), `samples[]` → `frames[]` → per-hand: wrist world
  transform (16 floats) + joints as flat array of 25 × [px,py,pz, qx,qy,qz,qw]
  wrist-relative, + tracked flags. Multiple takes per gesture as separate samples.
- **Canonical 25 joints** (ARKit HandSkeleton minus 2 forearm joints):
  wrist; per finger (thumb, index, middle, ring, little): metacarpal, knuckle/proximal,
  intermediate, distal, tip (thumb has no intermediate → 4 joints).
  USD rig names are snake_case (`index_finger_phalanx_proximal` etc.) — **always map
  joints by NAME, never by index** (left/right rig files list joints in different order).
- **Normalization:** wrist-relative (ARKit gives this), scale-normalized by
  wrist→middle-metacarpal distance, chirality-mirrored (left → right-hand canonical),
  orientation-invariance opt-in per gesture. Bimanual adds inter-hand relative transform.
- **Recognition (no ML in v1):**
  - Poses: feature vector (5 finger curls, 4 splay angles, 4 thumb-to-fingertip
    distances, optional palm normal) + weighted distance, **hysteresis** (tight enter /
    loose exit threshold) + **hold time ~200 ms**.
  - Motions: DTW over feature trajectories resampled to 32 frames, motion-energy
    start/end spotting on a sliding window.
  - Bimanual: concatenated per-hand features + inter-hand transform features.
  - Recognizers sit behind a protocol so a Core ML backend can slot in later.
- **Rendered previews (no ReplayKit/passthrough capture on visionOS):** drive the rigged
  hand models with recorded data, render offscreen via `RealityRenderer` → PNG thumbnail
  (poses) / MP4 replay (motions, 12 fps data interpolated to 30 for smoothness).
  Save to app documents AND to Photos via `PHAssetCreationRequest` with **add-only**
  authorization.
- **Playback:** both (a) 3D ghost replay in the immersive space (scrub/loop) and
  (b) flat preview (PNG/MP4) in the library window.
- **Hand models:** `_resources/3DModels/LeftHand_rigged.usdz` + `RightHand_rigged.usdz`
  (re-exported 2026-07-07 from Blender 5.1: proper wrist-rooted bone hierarchy, Y-up,
  meters, no lights, verified with usdchecker; originals `LeftHand.usdz`/`RightHand.usdz`
  are flat-hierarchy — don't use). 1,360 verts, 4 influences/vertex, tips unweighted.
  Retargeting: rotation-only onto rig local rotations (keep model bone lengths), with a
  calibration-offset hook in case rig bind frames differ from ARKit joint frames
  (verify visually on device; risk noted).

## Project layout

- Xcode 26.6, visionOS 26.5 target, **synced file groups** → new files dropped under
  `GestureCapture/` are auto-included in the app target; non-source files become
  bundle resources. No pbxproj editing needed.
- `GestureCapture/GestureKit/` — the future SPM package. **No app-specific imports
  inside this folder** (SwiftUI views stay out; RealityKit/ARKit/Photos OK).
  - `Model/` — JSON schema types, canonical joint list + ARKit/rig name mapping
  - `Capture/` — ARKitSession/HandTrackingProvider wrapper, recorder (countdown,
    modes, 30→12 fps downsample)
  - `Normalization/` — hand-local frame, scaling, mirroring, feature extraction
  - `Recognition/` — pose recognizer, DTW motion recognizer, event types, protocol
  - `Rendering/` — skeleton overlay entity, rigged-hand entity + retargeter,
    offscreen renderer (PNG/MP4), Photos saver
  - `Storage/` — GestureStore (Documents/Gestures/, bundle: json + png + mp4)
- `GestureCapture/Resources/` — the two `*_rigged.usdz` copied in as bundle resources.
- App layer: `AppModel` (capture controller + store wiring), `ContentView` (library
  window: list, detail w/ preview + playback, capture controls), `ImmersiveView`
  (live overlay, countdown attachment, ghost replay, live-test mode).
- `Info.plist`: add `NSHandsTrackingUsageDescription`,
  `NSPhotoLibraryAddUsageDescription`. Main window: switch volumetric → regular
  window for the library UI (also update scene manifest role).

## Build steps & status

- [x] **1. Foundations**: plan file (this), rigged usdz copied to
      `GestureCapture/Resources/`, Info.plist permission strings added, main window
      volumetric → regular (+ scene manifest role updated).
- [x] **2. GestureKit/Model**: `Model/HandJoint.swift` (25 joints, ARKit + rig-name
      mapping, parent table), `Model/GestureData.swift` (schema + packed 25×7 float
      joints + simd pack/unpack helpers).
- [x] **3. GestureKit/Capture**: `Capture/HandTrackingService.swift`,
      `Capture/GestureRecorder.swift` (countdown → capture 30 Hz → median frame for
      snapshot / 12 fps downsample for motion).
- [x] **4. Normalization + Recognition**: `Normalization/PoseFeatures.swift` (13-dim
      invariant vector, +3 orientation, 32 bimanual), `Recognition/GestureRecognition.swift`
      (PoseMatcher hysteresis 0.10/0.16 + 200 ms hold; MotionMatcher DTW threshold 0.09,
      resample 32; energy segmentation 0.25/0.12 m/s; `GestureRecognitionEngine`).
- [x] **5. Storage**: `Storage/GestureStore.swift` (Documents/Gestures,
      `<uuid>.gesture.json` + `.png` + `.mp4`).
- [x] **6. Rendering**: `Rendering/HandSkeletonOverlay.swift`,
      `Rendering/RiggedHandEntity.swift` (name-matched, rotation-only default,
      `.fullTransform` fallback mode), `Rendering/GestureReplayer.swift` (loop/scrub,
      12 fps slerp interpolation, re-based placement).
- [x] **7. Offscreen PNG/MP4**: `Rendering/GesturePreviewRenderer.swift`
      (RealityRenderer — NOTE API: `CameraOutput(.singleProjection(colorTexture:))`,
      `updateAndRender(deltaTime:cameraOutput:onComplete:)`), VideoWriter (AVAssetWriter
      h264 mp4), `Rendering/PhotoLibrarySaver.swift` (add-only auth).
- [x] **8. App UI**: `AppModel.swift` (services + save/append/preview flows),
      `ContentView.swift` (NavigationSplitView library, naming sheet, capture ornament,
      detail w/ VideoPlayer + ShareLink), `ImmersiveView.swift` (30 Hz update loop,
      overlays, status-panel attachment, ghost replay).
- [x] **9. Compiles green** for device SDK: `xcodebuild -destination
      'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED.
      (User tests on device; simulator intentionally skipped.)
- [x] **10. On-device verification round 1** (2026-07-07): capture/JSON/live overlay
      worked; rendered hand was stuck at rest pose → fixed (see step 11). Sample
      recording kept at `_captures/Thumbsup-Left.gesture.json` (verified: perfect
      thumbs-up data — thumb 28° bend, fingers ~250–260°).
- [x] **11. Retargeting fix + macOS debug harness.** Root cause: ARKit joint frames
      point +X along the bone, the rig's frames point −Z along the bone — direct
      rotation replacement produced ~rest pose (189 mm FK error). Fix in
      `RiggedHandEntity`: runtime per-joint calibration Q (rig frame = ARKit
      frame · Q), global Q solved by TRIAD on the wrist→metacarpal fan (pose-
      independent), per-joint bone-axis refinement, roll from global Q; rig local
      rotation = Q_parent⁻¹ · R_arkit · Q_joint; entity placement includes Q_wrist.
      FK error now 11–23 mm (model-vs-user proportions). Verified visually via
      **Tools/RetargetLab** (`swift run RetargetLab [json] [outDir]` — root
      Package.swift builds GestureKit for macOS; GestureKit files carry
      `#if os(visionOS)` guards for ARKit-dependent parts). Replay re-base now keeps
      recorded wrist ORIENTATION (thumbs-up renders thumb-up); preview camera
      reconstructs the recorder's viewpoint (head ≈ (0,1.55,0) in ARKit world).
- [x] **12. UI round 2** (per user sketch, 2026-07-07): `TabView` with 3 sections —
      **Gestures** (list + detail, as before), **Record** (settings form left; right:
      big red record button → big countdown digits → green tenths counter counting UP
      + white end-flash; snapshot plays `shutter.mp3`, timed capture plays
      `notif-register.mp3` at start / `notif-success.mp3` at end via `SoundPlayer`),
      **Live Test** (non-clickable library list left; right: big matched-gesture name,
      % match, thumbnail — stays until next detection via `AppModel.lastMatch`).
      Top ornament: tracking status dot (green/gray). Bottom ornament: big
      **Track Hands / Stop Tracking** button (`ToggleImmersiveSpaceButton`).
      Immersive StatusPanel mirrors the green tenths counter. Sounds live in
      `GestureCapture/Resources/` (shutter.mp3, notif-register.mp3, notif-success.mp3).
- [ ] **13. On-device verification round 2** (user): correct thumbnail/replay pose,
      new 3-section UI, sounds, counters, live-test match display. Watch items:
      recognizer thresholds still first-guess (GestureRecognition.swift constants);
      Q-calibration for RIGHT hand assumed symmetric (validated only on left so far —
      if right renders wrong, drop a right-hand JSON in _captures/ and run RetargetLab
      on it); preview background opaque dark gray.
- [x] **14. Consumer documentation**: `README.md` at repo root — full `.gesture.json`
      spec (schema, joint order/hierarchy, conventions, handedness semantics), Python
      + Swift ingestion examples, matcher recipe with v1 thresholds, rig bone-naming
      + −Z/+X frame-convention warning, RetargetLab usage, versioning rule.
- [ ] **15. Extract `GestureKit` to a proper SPM package.** (Multi-platform guards
      already in place; root Package.swift already builds it as a library for macOS;
      consumer docs already in README.)

## Current status

**Rounds 1–12 complete (2026-07-07). visionOS device build green; macOS tools build
green.** Next: user device-tests round 2 (step 13). To debug retargeting locally:
drop a `.gesture.json` in `_captures/` and `swift run RetargetLab _captures/<file> out`
— renders PNG/MP4 without a headset.

## Verification commands

```bash
# build
xcodebuild -project GestureCapture.xcodeproj -scheme GestureCapture \
  -destination 'generic/platform=visionOS Simulator' build
# inspect a usdz
xcrun usdcat <file.usdc> -o out.usda && xcrun usdchecker <file.usdc>
```
