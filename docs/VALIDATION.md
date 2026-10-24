# Demo 1 validation record

Date: 2026-10-24. Host: Apple Silicon MacBook Air, 16 GB, macOS 27, Swift 6.4, Python 3.9. Models and Python dependencies are installed locally; about 700 MB of weights and 604 MB of environment files are excluded from Git.

## Automated checks

Final checks after code corrections:

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

The signed app was opened with `--ui-preview` and inspected through the actual window screenshot and accessibility tree. Camera selectors, geometry fields, calibration, start/stop, voice controls, item controls and status text fit and are readable. This mode does not request motion, microphone or camera access. `--ui-smoke` additionally exercises window creation and a cached view PNG, then exits; macOS compositor-rendered controls are verified using the actual window, not that cached PNG.

## Hardware acceptance still required

The Mac's camera inventory during inspection listed its built-in camera and an iPhone Continuity Camera. The requested pair of cap-mounted USB cameras was not available for a physical run. AirPods calibration involves a physical right-head-turn and cannot be established by software simulation.

Before any supervised walking test:

- Connect the actual two USB cameras and motion-capable AirPods. Verify front/feet assignment and that previews correspond to the physical view. Grant app permissions through macOS.
- Measure camera FOV, mounting angles and cap height; estimate a depth scale from several known ranges. Confirm floor exclusion and alert positions while standing still. Check left/right/front cues on AirPods and normal stereo output with voice enabled.
- Find the actual backpack and white cane in varied indoor lighting, against clutter, with partial occlusions and multiple similar objects. Measure missed detections, false detections, direction errors, range errors and target loss. Category detection does not prove ownership.
- Check obstacle alerts while finding an item. Confirm urgent hazards suppress the item, off-path objects do not dominate, and camera disconnection, head-tracking loss, tilted head, out-of-view walking direction and slow inference announce a pause.
- Test only slow, supervised straight segments with an existing mobility aid. Reset walking direction before a turn. Assess latency while moving; this implementation has no translation tracking, drop-off detection, route planning or validated stopping distance.

No real-world walking reliability, white-cane detection accuracy, personal-item recognition, listening comfort or blind-participant validation is claimed by the automated tests.
