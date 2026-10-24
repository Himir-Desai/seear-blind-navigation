# Seear Demo 1

A native macOS indoor demo for two cap-mounted RGB USB cameras and motion-capable AirPods. Neutral mode plays a spatial alert for the nearest estimated obstacle in the walking corridor. Item-finding mode accepts “Hey Seear, where is my backpack” or “Hey Seear, where is my white cane” and keeps obstacle monitoring active while guiding toward the visible item.

This is a supervised research demo. RGB distances are estimates; silence never means a clear path. Continue using a cane and a sighted guide. Real cap-camera performance must be measured before relying on the cues.

## Setup and run

Requires Apple Silicon macOS 14+, Xcode command-line tools, Python 3.9+, two distinct USB cameras, and motion-capable AirPods. The initial model/dependency setup needs internet; subsequent inference is local with cached weights. The app expects this checkout and its `.venv` to remain in place; rebuild if moving it.

```bash
bash scripts/setup-vision.sh
bash build.sh
bash run.sh
```

Grant Camera, Motion & Fitness, and (when enabling voice) Microphone and Speech Recognition permissions to Seear. Run the signed app via `run.sh`, not the bare SwiftPM executable. Ad-hoc signatures can cause macOS to ask again after a rebuild; set `CODESIGN_ID` to your stable signing identity if you have one.

1. Connect both cameras. Select the front and feet devices; do not select the same device twice.
2. Enter each camera's measured horizontal FOV, downward mount angle and cap height. The displayed defaults are placeholders. Set depth scale from known indoor test distances; this does not make monocular estimates reliable measurements.
3. Wear AirPods, select them as macOS output, and use a comfortable volume. Prefer the Mac microphone for speech; an AirPods microphone route can reduce audio quality.
4. Face forward and press Calibrate. Turn your head right about 30° and press Calibrate again. Face the intended walking direction and press Set forward.
5. Start guidance. Wait for local vision to load and for fresh results from both cameras. Previews and status are for a sighted supervisor; essential failures and search state changes also have spoken feedback.
6. Use the Find field, or Enable voice and say the wake phrase plus a command. “Hey Seear, stop” cancels the item search while retaining obstacle monitoring. Disable voice stops the microphone.
7. Keep near the calibrated head pitch and walk only a supervised straight segment. Before walking in a new direction, face it and press Set forward or say “Hey Seear, set forward”. Stop guidance ends both camera feeds and the vision worker.

The item cue is a pulsed broadband/440 Hz sound, with faster pulses and stronger level when the estimated item is nearer. The obstacle cue is higher pitched and faster. Sounds indicate object locations, not a safe direction to walk. A close hazard suppresses the item sound; other in-path hazards duck it. Target loss stops its directional cue; Find again to select a different instance. Thin white canes may be missed and require specific real-scene evaluation.

## Implementation and evidence

The app uses AppKit, AVFoundation HRTFHQ, CoreMotion and on-device Speech. A private Python worker runs OWLv2 text-conditioned detection and Depth Anything V2 Metric Indoor Small on MPS when available, otherwise CPU. No frames/audio are sent to an inference service. Capture, inference, geometry, guidance and audio are separate modules for future backend replacement.

[Prototype findings](docs/PROTOTYPE_FINDINGS.md) explains why the item cue starts from Hybrid 2.1 and why hazard alerts use a different policy. The latest small P4 comparison favored Hybrid's first-press error but found slower searches; no perceptual or safety superiority is established. [Architecture](docs/ARCHITECTURE.md) records coordinates, state, deadlines and limitations.

## Validation

```bash
bash verify.sh
open -n build/Seear.app --args --ui-smoke
```

The UI smoke command writes `build/ui-smoke.png` and exits without opening cameras or starting head tracking. Automated checks do not replace a supervised cap-camera/AirPods trial. See [validation record](docs/VALIDATION.md) for checks actually performed and the remaining hardware checks.

Repository: [Himir-Desai/seear-blind-navigation](https://github.com/Himir-Desai/seear-blind-navigation).
