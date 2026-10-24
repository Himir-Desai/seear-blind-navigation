# Demo 1 validation record

Date: 2026-10-24. Host: Apple Silicon MacBook Air, 16 GB, macOS 27, Swift 6.4, Python 3.9. Models and Python dependencies are installed locally; about 700 MB of weights and 604 MB of environment files are excluded from Git.

## Automated checks

Initial Demo 1 baseline, before B3:

| Check | Result |
| --- | --- |
| Release build and ad-hoc signed app | Passed |
| Swift guidance, command and motion-history tests | 12 passed |
| Python geometry and subprocess-protocol tests | 5 passed |
| Actual offline HRTF graph | 6 passed: left/right, −23-sample interaural delay, correct head rotation, two-voice headroom, fault silence |
| Native → cached ML → native smoke | 8 alternating frames passed; two cats detected per frame; mean inference 446 ms; maximum oldest-frame age immediately before/after replies 1.365 s |
| Signature, plist and shell syntax checks | Passed |
| Python dependency consistency | Passed (`pip check`) |
| Native window screenshot/accessibility inspection | Readable controls and complete layout verified |

Run `bash verify.sh` for the signed release build, Swift core tests, Python geometry/protocol tests, real offline HRTF rendering and signature validation.

The ML smoke check is separate because it loads both models and requires an example image. It uses the public two-cat image linked from the Hugging Face documentation dataset, not user camera footage. Save the sample locally once:

```bash
mkdir -p build
curl --fail --location 'https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/coco_sample.png' --output build/inference-sample.png
build/Seear.app/Contents/MacOS/SeearDemo --vision-check
```

The check sends eight alternating front/feet frames through the **actual Swift JPEG encoder, subprocess pipes, cached models, Python geometry and Swift scene decoder**. It checks for cat boxes and finite geometry, and compares the maximum oldest-camera capture age immediately before and after replies with the unchanged 1.5-second deadline. This establishes software integration and a sample-image cadence, not cap-camera detection accuracy. More expensive frames or CPU fallback can exceed the deadline; the app then pauses guidance instead of using stale results.

Model revisions are pinned in `vision/backend.py`. The detector uses float16 on MPS and float32 on CPU; depth uses float32. Model graph warm-up occurs before the worker reports ready. Cached-only model loading, `HF_HUB_OFFLINE=1`, and no remote inference are used by the runtime worker. A runtime warning from urllib3 on the macOS-provided Python's LibreSSL is present; model download succeeded, and runtime inference is offline. Python 3.10+ with an OpenSSL build can avoid that warning in a fresh environment.

## Native UI

The initial signed app was opened with `--ui-preview` and inspected through the actual window screenshot and accessibility tree. Camera selectors, geometry fields, the original calibration controls, start/stop, voice controls, item controls and status text fit and were readable. B3 removes those calibration controls and updates the wearer instructions; its UI recheck is recorded below. This mode does not request motion, microphone or camera access. `--ui-smoke` additionally exercises window creation and a cached view PNG, then exits; macOS compositor-rendered controls are verified using the actual window, not that cached PNG.

## Hardware acceptance still required

The Mac's camera inventory during inspection listed its built-in camera and an iPhone Continuity Camera. The requested pair of cap-mounted USB cameras was not available for a physical run. B3 initializes the motion reference automatically. Physical left/right alignment, turn behavior and microphone recognition still cannot be established by software simulation.

Before any supervised walking test:

- Connect the actual two USB cameras and motion-capable AirPods. Verify front/feet assignment and that previews correspond to the physical view. Grant app permissions through macOS.
- Measure camera FOV, mounting angles and cap height; estimate a depth scale from several known ranges. Confirm floor exclusion and alert positions while standing still. Check left/right/front cues on AirPods and normal stereo output with voice enabled.
- Find the actual backpack and white cane in varied indoor lighting, against clutter, with partial occlusions and multiple similar objects. Measure missed detections, false detections, direction errors, range errors and target loss. Category detection does not prove ownership.
- Check obstacle alerts while finding an item. Confirm urgent hazards suppress the item, off-path objects do not dominate, and camera disconnection, head-tracking loss, tilted head and slow inference announce a pause. Turn through 90°/180° without any reset and verify that the alert corridor follows the camera. Confirm spoken pause/resume works without touching the Mac and that resume waits for new frames.
- Test slow supervised movement and turns with an existing mobility aid. Looking sideways can leave the actual travel path outside the cap cameras; the software does not estimate body travel direction. No manual direction reset is required. Assess latency while moving; this implementation has no translation tracking, drop-off detection, route planning or validated stopping distance.

No real-world walking reliability, white-cane detection accuracy, personal-item recognition, listening comfort or blind-participant validation is claimed by the automated tests.

## B3 camera-forward and hands-free correction

The fixed walking-heading gate and wearer-facing calibration controls were removed. Forward now follows current cap-camera/head yaw. Startup establishes an arbitrary motion reference automatically, retains capture-to-playback rotation compensation, enables local voice, and supports spoken pause/resume without a Mac click. A new motion reference discards old capture history and in-flight scenes.

B3 validation completed:

- `bash verify.sh`: signed release build, 18 Swift tests, 5 Python tests and all 6 real HRTF checks passed.
- New regressions cover left/right/about-turns, the ±180° seam, a fixed scene during a head turn, a newly forward hazard after a turn, automatic first-sample reference, motion reconnection, rejected old motion, wake-word commands and paused/resumed scene freshness.
- The native `--ui-preview` window was checked through its actual screenshot and accessibility tree. Calibration/Set forward buttons are absent, backend/debug controls and voice instructions are visible, and the full layout remains readable. The preview kept cameras, microphone and motion services off. Its camera inventory listed the built-in camera and one USB camera at this inspection.
- Shell syntax and whitespace checks passed. Model code and the scene pipe contract were unchanged; the real-model benchmark above remains the initial baseline and was not rerun for this correction.

Voice tests exercise command parsing and guidance state, not physical speech recognition. Actual microphone reach, on-device recognition availability, AirPods left/right alignment and cap-camera turn behavior require supervised hardware acceptance. No such acceptance is claimed.
