# Seear Demo 1

A native macOS indoor demo for two cap-mounted RGB USB cameras and motion-capable AirPods. Neutral mode plays a spatial alert for the nearest estimated obstacle in a corridor ahead of the cap camera. Forward follows the head as the wearer turns; no direction reset is needed. Item-finding mode accepts “Hey Seear, where is my backpack” or “Hey Seear, where is my white cane” and keeps obstacle monitoring active while guiding toward the visible item.

This is a supervised research demo. RGB distances are estimates; silence never means a clear path. Continue using a cane and a sighted guide. Real cap-camera performance must be measured before relying on the cues.

## Setup and run

Requires Apple Silicon macOS 14+, Xcode command-line tools, Python 3.9+, two distinct USB cameras, and motion-capable AirPods. The initial model/dependency setup needs internet; subsequent inference is local with cached weights. The app expects this checkout and its `.venv` to remain in place; rebuild if moving it.

```bash
bash scripts/setup-vision.sh
bash build.sh
bash run.sh
```

During backend setup, grant Camera, Motion & Fitness, Microphone and Speech Recognition permissions to Seear. Run the signed app via `run.sh`, not the bare SwiftPM executable. Ad-hoc signatures can cause macOS to ask again after a rebuild; set `CODESIGN_ID` to your stable signing identity if you have one.

The Mac interface is for the developer or sighted supervisor to configure and debug the backend. Once the backend is running, the wearer controls it by voice and does not need to use the Mac.

1. **Backend setup:** connect both USB cameras and select front/feet devices. Enter their measured FOV, mount angles, cap height and depth scale. The feet angle defaults to 90° for a straight-down camera; use its actual mounting angle if tilted. Defaults are placeholders; RGB estimates remain uncertain.
2. Select stereo AirPods output and a microphone that can hear the wearer at the intended demo distance. A Mac microphone works only within its usable range. Check that voice input preserves stereo headphone output.
3. With the cap and AirPods worn at the normal head pitch, start the backend. AirPods motion gets an arbitrary reference automatically, and local voice listening starts automatically. Confirm the left/right cue alignment during setup. No face-forward/right-turn button calibration is required.
4. Wait for the spoken “Guidance active” message. Both cameras and head tracking must supply fresh data before directional cues play.
5. The wearer can say “Hey Seear, where is my backpack” or “Hey Seear, where is my white cane”. “Hey Seear, stop” cancels the item search while obstacle monitoring continues.
6. “Hey Seear, pause guidance” mutes directional guidance and keeps voice listening active. “Hey Seear, resume guidance” resumes the selected search and obstacle monitoring after fresh camera results arrive. “Stop guidance” and “start guidance” are equivalent voice commands.
7. Turn naturally: camera-forward follows the cap automatically, including right-angle and about-turns. Large changes in head pitch still pause geometry-based guidance; returning to the starting pitch restores it without a click. The backend's manual controls are debug overrides.

The monitored corridor follows **head direction**, not an inferred body travel direction. Looking sideways while continuing to walk can leave the travel path outside the camera view. This version does not claim to monitor unseen hazards or infer walking intent. Supervised turn testing is still required.

The item cue is a softer single broadband/440 Hz pulse. Obstacle alerts are brighter **two-note double beeps (1200/1800 Hz)** with a clear gap. Both accelerate and strengthen as the estimated distance decreases, and both use spatial audio. Sounds indicate object locations, not a safe direction to walk. A close hazard suppresses the item sound; other in-path hazards duck it. A search initially picks only the highest-confidence valid match across both fresh feeds, then keeps that item using feed, bearing/range and bounding-box continuity. The preview shows only that selected match and its score. A higher-scoring newcomer does not replace it. Target loss stops its directional cue; repeat the voice Find command to select a different instance. A backend/motion-reference reset requires Find again because the previous identity cannot be retained in a new frame. Thin white canes may be missed and require specific real-scene evaluation.

The feet feed uses local shoe/leg detection plus RGB and estimated near-body checks to reduce alerts from worn footwear. It does not ignore an entire near-feet area. The debug status shows candidate shoes and excluded pixels, and obstacle text identifies the camera and **horizontal** range. See [footwear filtering](docs/FOOTWEAR_FILTER.md) for limits and the physical regression check.

## Room memory and floorplan

Backend setup enables **Build room memory** by default. The front camera automatically builds and saves landmarks, an estimated camera path, observed floor cells and partial wall segments. **Room map (debug)** displays them and saved-place recognition; lost/stale poses disappear. Unseen areas stay unknown. Live guidance works without a map or scan.

See [room mapping](docs/ROOM_MAPPING.md) for reuse, limits, local storage and model licensing. This is experimental RGB geometry, with no complete-floorplan or survey-accuracy claim. Optional phone LiDAR scans are a future extension and will require alignment to the live camera map.

## Implementation and evidence

The app uses AppKit, AVFoundation HRTFHQ, CoreMotion and on-device Speech. A private Python worker runs OWLv2 text-conditioned detection and Depth Anything V2 Metric Indoor Small on MPS when available, otherwise CPU. Optional room memory uses OpenCV landmarks and a cached SegFormer wall/floor model in a background thread. No frames/audio are sent to an inference service. Capture, inference, geometry, guidance and audio are separate modules for future backend replacement.

[Prototype findings](docs/PROTOTYPE_FINDINGS.md) explains why the item cue starts from Hybrid 2.1 and why hazard alerts use a different policy. The latest small P4 comparison favored Hybrid's first-press error but found slower searches; no perceptual or safety superiority is established. [Architecture](docs/ARCHITECTURE.md) records coordinates, state, deadlines and limitations.

## Validation

```bash
bash verify.sh
open -n build/Seear.app --args --ui-smoke
```

`bash verify.sh` also writes `build/item-cue.wav` and `build/obstacle-cue.wav` for comparing the two rendered sounds on headphones.

The UI smoke command writes `build/ui-smoke.png` and exits without opening cameras or starting head tracking. Automated checks do not replace a supervised cap-camera/AirPods trial. See [validation record](docs/VALIDATION.md) for checks actually performed and the remaining hardware checks.

Repository: [Himir-Desai/seear-blind-navigation](https://github.com/Himir-Desai/seear-blind-navigation).
