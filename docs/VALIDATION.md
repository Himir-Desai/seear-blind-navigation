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

The ML smoke check is separate because it loads the cached models and requires an example image. It uses the public two-cat image linked from the Hugging Face documentation dataset, not user camera footage. Save the sample locally once:

```bash
mkdir -p build
curl --fail --location 'https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/coco_sample.png' --output build/inference-sample.png
build/Seear.app/Contents/MacOS/SeearDemo --vision-check
```

The check sends eight alternating front/feet frames through the **actual Swift JPEG encoder, subprocess pipes, cached models, Python geometry and Swift scene decoder**. It checks for cat boxes, finite geometry and round-tripped quaternion attitude (synthetic 20° pitch/25° roll on the public image), and compares the maximum oldest-camera capture age immediately before and after replies with the unchanged 1.5-second deadline. This establishes software integration and a sample-image cadence, not cap-camera detection accuracy. More expensive frames or CPU fallback can exceed the deadline; the app then pauses guidance instead of using stale results.

Model revisions are pinned in `vision/backend.py`. The detector uses float16 on MPS and float32 on CPU; depth uses float32. Model graph warm-up occurs before the worker reports ready. Cached-only model loading, `HF_HUB_OFFLINE=1`, and no remote inference are used by the runtime worker. A runtime warning from urllib3 on the macOS-provided Python's LibreSSL is present; model download succeeded, and runtime inference is offline. Python 3.10+ with an OpenSSL build can avoid that warning in a fresh environment.

## Native UI

The initial signed app was opened with `--ui-preview` and inspected through the actual window screenshot and accessibility tree. Camera selectors, geometry fields, the original calibration controls, start/stop, voice controls, item controls and status text fit and were readable. B3 removes those calibration controls and updates the wearer instructions; its UI recheck is recorded below. This mode does not request motion, microphone or camera access. `--ui-smoke` additionally exercises window creation and a cached view PNG, then exits; macOS compositor-rendered controls are verified using the actual window, not that cached PNG.

## Hardware acceptance still required

The Mac's camera inventory during inspection listed its built-in camera and an iPhone Continuity Camera. The requested pair of cap-mounted USB cameras was not available for a physical run. B3 initializes the motion reference automatically. Physical left/right alignment, turn behavior and microphone recognition still cannot be established by software simulation.

Before any supervised walking test:

- Connect the actual two USB cameras and motion-capable AirPods. Verify front/feet assignment and that previews correspond to the physical view. Grant app permissions through macOS.
- Measure camera FOV, mounting angles and cap height; estimate a depth scale from several known ranges. Confirm floor exclusion and alert positions while standing still. Check left/right/front cues on AirPods and normal stereo output with voice enabled.
- Find the actual backpack and white cane in varied indoor lighting, against clutter, with partial occlusions and multiple similar objects. Measure missed detections, false detections, direction errors, range errors and target loss. Category detection does not prove ownership.
- Check obstacle alerts while finding an item. Confirm urgent hazards suppress the item, off-path objects do not dominate, and camera disconnection, head-tracking loss and slow inference announce a pause. Nod and roll through small/large angles while standing still: tilt alone must keep processing active, keep the floor excluded and preserve cue direction. Turn through 90°/180° without any reset and verify that the alert corridor follows the camera. Confirm spoken pause/resume works without touching the Mac and that resume waits for new frames.
- Test slow supervised movement and turns with an existing mobility aid. Looking sideways can leave the actual travel path outside the cap cameras; the software does not estimate body travel direction. No manual direction reset is required. Assess latency while moving; audio does not use the experimental map translation, and there is no drop-off detection, route planning or validated stopping distance.

No real-world walking reliability, white-cane detection accuracy, personal-item recognition, listening comfort or blind-participant validation is claimed by the automated tests.

## B3 camera-forward and hands-free correction

The fixed walking-heading gate and wearer-facing calibration controls were removed. Forward now follows current cap-camera/head yaw. Startup establishes an arbitrary motion reference automatically, retains capture-to-playback rotation compensation, enables local voice, and supports spoken pause/resume without a Mac click. A new motion reference discards old capture history and in-flight scenes.

B3 validation completed:

- `bash verify.sh`: signed release build, 18 Swift tests, 5 Python tests and all 6 real HRTF checks passed.
- New regressions cover left/right/about-turns, the ±180° seam, a fixed scene during a head turn, a newly forward hazard after a turn, automatic first-sample reference, motion reconnection, rejected old motion, wake-word commands and paused/resumed scene freshness.
- The native `--ui-preview` window was checked through its actual screenshot and accessibility tree. Calibration/Set forward buttons are absent, backend/debug controls and voice instructions are visible, and the full layout remains readable. The preview kept cameras, microphone and motion services off. Its camera inventory listed the built-in camera and one USB camera at this inspection.
- Shell syntax and whitespace checks passed. Model code and the scene pipe contract were unchanged; the real-model benchmark above remains the initial baseline and was not rerun for this correction.

Voice tests exercise command parsing and guidance state, not physical speech recognition. Actual microphone reach, on-device recognition availability, AirPods left/right alignment and cap-camera turn behavior require supervised hardware acceptance. No such acceptance is claimed.

## Feature 2: room memory and partial wall/floorplan reconstruction

Validation completed on the same host:

- Signed release build, 20 Swift tests, 17 Python tests and all 6 actual HRTF checks passed. New tests cover 6-DoF pose recovery with outliers, weak/depth-inconsistent match rejection, real ORB save/reload/relocalization, tracking loss without map extension, calibration mismatch, unknown/dynamic surfaces, synthetic wall/floor geometry, persisted floorplans, corrupt/unsupported files, atomic write failures, revision conflicts and mapping/live-scene isolation.
- The geometry fixture raycasts a known rectangular room and checks reconstructed wall endpoints against its planes. Repeated distinct views support wall estimates, a stationary repeated view does not increase wall support, and the unseen rear boundary is not invented. This tests the geometry algorithm with known labels/depth; it does not measure model accuracy.
- The actual cached SegFormer CPU model, OWLv2/Depth Anything MPS models and native map/scene decoders ran together over eight alternating public sample-image frames. The final isolated mapping-enabled run averaged **436 ms/frame**, with maximum oldest-feed age **1.362 s**, below the unchanged **1.5 s** deadline. The no-mapping comparison averaged 442 ms and 1.343 s. An earlier run overlapping UI work failed at 1.975 s; another isolated run passed at 1.432 s. Timing remains load-dependent, and stale live results still pause guidance.
- Native screenshots and accessibility inspection verified the backend mapping checkbox/button and the separate labelled synthetic floorplan window. The stale camera marker was suppressed and unknown regions remained blank. UI preview requested no camera/microphone/motion feeds. Two USB devices were listed during this inspection, but their cap mounting, geometry and live performance were not tested.
- `pip check`, shell syntax and Git whitespace checks passed. Map smoke files live under ignored unique `build/mapping-smoke-*` folders, never the wearer's map directory. The synthetic UI fixture is explicitly labelled; it is not evidence of a physical room scan.

Run the map UI check separately from the ML timing check:

```bash
.venv/bin/python scripts/mapping-ui-fixture.py
open -n build/Seear.app --args --ui-map-smoke
# After UI checks finish:
build/Seear.app/Contents/MacOS/SeearDemo --vision-check
# Optional live-vision comparison:
build/Seear.app/Contents/MacOS/SeearDemo --vision-check --no-mapping
```

The final Python checks have no matrix warnings after replacing the tiny batched BLAS operations with equivalent explicit contractions (finite-input/output comparison agreed exactly on this host). Cached SegFormer emits an ignored `reduce_labels` processor-configuration warning; inference returns native map messages successfully. The existing LibreSSL warning also remains.

Physical acceptance must now additionally measure path drift and range/scale error, wall displacement and missed/false wall segments, saved-place recovery after restart and lighting/viewpoint changes, repeated-room ambiguity, head turns/tilts, furniture movement and map loss/recovery while live alerts continue. No physical floorplan accuracy, full-room completeness, route safety or blind-participant validation is claimed. See [room mapping](ROOM_MAPPING.md) for limits and the optional future phone registration design.

## B4: own-shoe obstacle rejection

User confirmed two cap cameras at roughly 5–6 ft and chose detected footwear with near-body checks. The original occupancy code produced two false alerts on an analytic 16 cm-high shoe near the wearer (nearest horizontal range 0.153 m). The implemented filter excludes only supported shoe/linked-leg foreground pixels, leaving item observations and depth coverage intact. Fully downward 90° geometry is now supported and is the feet setup default.

Completed checks:

- `bash verify.sh`: signed release build, **20 Swift tests**, **26 Python tests** and **6 actual HRTF checks** passed. Regressions reproduce the shoe false hazard and verify its removal, a nearby low obstacle, a closer object inside the shoe box, distant/front-feed footwear, linked vs unsupported legs, weak/missing detections, segmentation failure, unchanged target observations/coverage, neutral-mode worker integration, and floor geometry at 55°/70°/90° and 5–6 ft heights.
- Actual cached-model/native check with room memory enabled, eight alternating frames, front 0° and feet 90°: two cat targets remained present; footwear metadata decoded and returned `no_match` on the cat image. Mean inference **441 ms**, maximum oldest-feed age **1.435 s**, below the unchanged 1.5 s cutoff. This was rerun after adjusting the smoke fixture to use the real feet angle. The earlier 0° feet smoke run averaged 452 ms and approached the cutoff (rounded 1.500 s); latency headroom remains limited under load.
- Additional actual OWLv2/depth inference on the [official Ultralytics bus photograph](https://raw.githubusercontent.com/ultralytics/assets/main/im/bus.jpg), resized to at most 640×640, returned six shoe proposals above 0.20 while retaining three independent `person` item results (455 ms). Its leg proposal scored below the suppression threshold. The file is ignored under `build/footwear-public-sample.jpg`. This checks real footwear-query execution, not ego-footwear ownership or cap-view recognition accuracy.
- Native screenshot/accessibility inspection confirmed the rebuilt feet default of 90.00°, full backend layout and hardware-free UI preview. Cameras/microphone/motion were not started. Whitespace and shell syntax checks passed.

No real cap footage was used for this correction's acceptance. The reported physical symptom still requires a stationary, supervised recheck with the actual shoes, measured mount geometry and nearby external objects. General RGB range accuracy is unchanged. See [filter details and hardware regression](FOOTWEAR_FILTER.md).

## 1.1: distinct cues and a single selected item

User chose highest-confidence acquisition followed by keeping that item. The item waveform retains its broadband/440 Hz single pulse. Obstacle alerts now use broadband 1200/1800 Hz double beeps; both remain mono HRTF sources. Only the selected item's box and score are drawn across both previews. Later higher-scoring candidates cannot replace the lock; missing association stops the item sound. Pause/resume and brief stale/tracking faults retain the lock, while a full backend/motion-reference reset requires a new voice Find command.

Validation completed:

- Signed release build, **24 Swift tests**, **26 Python tests**, signature validation, shell syntax and whitespace checks passed. New guidance regressions cover highest valid initial score across both feeds, a higher-scoring newcomer, nearby nonoverlapping boxes, target loss, repeated Find, stale/tracking faults, pause/resume and full reference reset. The existing urgent-hazard regression also verifies that tracking continues while item audio is suppressed.
- **9 actual HRTF checks** passed. Alongside left/right, −23-sample interaural delay, head rotation, real item+hazard headroom and fault mute, new rendered-signal checks verify the item's 440 Hz component, the hazard's 1200/1800 Hz components and distinct pulse counts: **27 hazard bursts vs 11 item pulses** over the same 2.73 s window at 1 m. Dominant-tone checks require at least 10× the opposite cue's reference-tone energy.
- `build/item-cue.wav` and `build/obstacle-cue.wav` are front-centred examples exported from the actual offline HRTF graph. Their WAV headers were checked: stereo, 48 kHz, 16-bit PCM, 2.731 s each. These are ignored generated artifacts. Signal differences do not establish perceptual distinguishability for a wearer.
- The native `--ui-item-preview` screenshot/accessibility state was inspected. Two synthetic candidates in front and another in feet produced just one green selected box (score 0.90) in front, with no feet box. Preview used the existing public cat sample, labelled synthetic, with camera/microphone/motion capture off.

Reproduce the UI smoke with the public sample from the ML-smoke instructions present:

```bash
open -n build/Seear.app --args --ui-item-smoke
```

It writes `build/item-ui-smoke.png` and exits. `--ui-item-preview` keeps the same synthetic case open. `bash verify.sh` writes both WAV comparisons as part of the audio check.

The detector/worker/model code and inference deadline are unchanged in 1.1, so cached-model latency was not rerun; the B4 result above remains the last measured baseline. Real cap/AirPods testing must check cue recognition while walking, stable association of similar nearby items and target loss. B5 remains open: a high-scoring false positive can still be selected. Association uses geometry/box continuity, not verified persistent visual identity or ownership.

## 1.2: item confidence cutoff and relative switching margin

The user selected x=0.50 and y=0.10, with switching relative to the current item's score rather than fixed x+y. Guidance acquires/shows/sounds an item only above x. A fresh challenger must beat the current associated score by more than y; equal-margin scores do not switch. A weak associated match can update the comparison score without producing a cue or box; a completely missing item uses its last observed score for comparison. No previous cue is replayed when the current observation is absent/below cutoff. Obstacle guidance remains independent.

Completed validation:

- Signed release build, **32 Swift tests**, **26 Python tests** and **9 actual HRTF checks** passed. Eight new policy/integration tests cover strict acquisition and drop-out boundaries, relative vs fixed thresholds, exact/near-decimal switching boundaries, weak/missing current detections, custom configuration, invalid numeric values, older challenger frames, cross-feed switching and retention inside the margin. Existing lock regressions were updated for the user-authorized automatic switching behavior; obstacle priority, pause/reset and fresh-scene checks still pass.
- Native `--ui-item-preview` screenshot/accessibility inspection verified readable **Min x=0.50** and **Switch +y=0.10** controls in the item row. The synthetic scenario acquired 0.65, observed its score fall to 0.60, and switched to a challenger at 0.75. Only the switched candidate's box/score appeared across both feeds. Hardware services stayed off.
- Configuration validates finite values, x≥0.15, y≥0 and x+y<1 before backend start; the controls follow the existing setup convention and are locked during a run. Core policy validation and applied nondefault values are covered by Swift tests. UI error speech/permission interaction was not exercised.
- Shell syntax and Git whitespace checks passed. Model/worker inference and freshness cutoffs did not change, so cached-model cadence was not rerun. The B4 timing baseline remains the last actual model/native measurement.

These thresholds filter model scores, not calibrated probabilities. No real positive/negative cap-footage evaluation was performed to select or calibrate them. A strict 0.50 cutoff can reject actual items as well as false detections; B5 remains unresolved. Validate the selected scores on actual present/absent item scenes before treating cue availability as evidence that an object is in view.

## B6: continuous pitch/roll compensation

Removed the 12° pitch gate. Capture-time AirPods quaternion attitude now compensates fixed-mount projection and wearer filtering; full current attitude controls HRTF and item direction-dependent shaping. Pitch/roll do not reset the automatic yaw origin. Item continuity checks box overlap only when full attitude is nearly unchanged. New maps seed gravity alignment from capture tilt; later visual poses are already 6-DoF. No map is required for live compensation.

Completed on this host:

- `bash verify.sh`: signed release build, **38 Swift tests**, **31 Python tests**, **17 actual HRTF checks** and signature verification passed. Tests cover initial nonlevel startup, combined turns/roll/nods, ±90° and inverted attitudes, yaw/quaternion seams, capture-time interpolation, missing/invalid motion, tilt-only guidance continuity, item-box movement, analytic floor exclusion under both mounts, retained real obstacles, visible footwear during tilt, map seeding/metadata and scene-pipe attitude transport.
- Both item and hazard HRTF outputs agree with equivalent head-relative sources (mean squared signal error <1e−8) at pitch/roll combinations 35°/40°, 90°/0°, −90°/70° and 130°/180°. Existing distinct-waveform, priority, confidence and fault-mute checks continue to pass.
- Actual Swift → cached models → Python geometry → Swift scene/map integration: eight alternating public-image frames with synthetic capture pitch 20°, roll 25°, front mount 0° and feet mount 90°. All frames returned two valid cat observations and the expected full attitude; optional mapping reached tracking and footwear metadata decoded. The final run averaged **450 ms/frame**, with maximum oldest-feed age **1.483 s** against the unchanged **1.5 s** limit. Earlier runs before reducing projection array work failed at 1.627 s and 1.507 s. This budget remains load-sensitive and has little headroom; a single passing smoke run does not establish continuous hardware throughput.
- Native hardware-free preview screenshot/accessibility inspection confirmed readable updated tilt instructions and unchanged setup fields. No camera/microphone/motion session was started. Shell syntax and whitespace checks passed.

Physical acceptance is still pending: with the cap secured and its angles measured relative to a level head, verify nod/roll signs, floor/shoe rejection and sound direction while tilting/turning, including starting with a tilted head. AirPods motion and RGB depth are estimates; neither cap slippage nor head translation is corrected by this change. Both cameras can lose coverage of the walking path during a glance/tilt, and severe viewpoints may degrade model estimates. Tilt alone no longer pauses processing; stale vision, inadequate depth coverage or genuine motion loss still suppress directional guidance. Earlier saved map files remain on disk but their pre-gravity-alignment provenance is not reused.
