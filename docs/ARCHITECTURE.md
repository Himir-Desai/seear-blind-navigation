# Demo 1 architecture

User-confirmed scope: this Mac, two RGB USB cameras on a cap, local processing with replaceable modules, and an indoor supervised demo.

## Data flow

```text
Front USB camera ─┐                         ┌─ text-conditioned item detector
                  ├─ latest JPEG ─ Python ─┤
Feet USB camera ──┘   + capture yaw/time     └─ indoor metric monocular depth
                                                    │
AirPods motion ─ calibration ─ current yaw           │ NDJSON scene
                              │                     ▼
Local speech ─ wake grammar ─ target query ─ guidance engine
                                                │
                                  target + nearest in-path hazard
                                                │
                              mono pulse voices → HRTFHQ → AirPods
```

`SeearCore` contains geometry, command parsing, freshness checks, approximate target continuity, corridor filtering and priority. It is independent of AppKit, cameras, ML and audio. `Camera` captures both USB devices using AVFoundation. `VisionWorker` sends one frame at a time over private process pipes and alternates feeds; old frames are replaced, not queued. `vision/backend.py` owns detector/depth inference; `vision/geometry.py` turns depth into observations. A different local or future cloud backend can implement `infer(image, target)` and retain the scene contract. No cloud inference or remote fallback is enabled.

The Python worker loads cached model weights only, refuses remote model code, and uses safetensors. The setup script downloads public weights and packages once. Images/audio are not recorded or uploaded. Python diagnostics go to ignored `build/vision.log`; no frame or voice-transcript logging is implemented.

## Coordinate and freshness contract

`+X` is right, `+Y` up, and `-Z` forward. Bearings are degrees clockwise from calibrated forward. An observation's bearing is relative to its camera at capture. The front and feet camera optical axes must be aligned in yaw with the cap's forward direction. Their different downward mount angles are entered separately. FOV assumes a rectilinear, square-pixel camera; strongly distorted/wide-angle video requires rectification before use.

Each sample's presentation timestamp is converted from the capture session's synchronization clock to the host's monotonic clock. Camera frames retain that time through inference; driver-delayed buffers do not receive a new time on delivery. Capture yaw is interpolated from timestamped AirPods samples, including across the ±180° seam; missing or stalled motion history rejects the frame. The guidance engine adds capture yaw once to obtain an absolute bearing, and the HRTF listener applies current yaw once. This avoids rotating a cap-mounted camera observation twice. AirPods calibration measures yaw sign using a deliberate right turn; neutral stays fixed until recalibration. macOS environmental automatic listener tracking is disabled in the audio graph.

There is no translational tracking, map or SLAM. The sound source's range/position is refreshed from the latest camera estimate. Between frames, head rotation is compensated but walking translation is not. This limitation matters near an object and when latency increases.

Both feeds must have estimated depth coverage ≥60% and capture age ≤1.5 seconds, and AirPods updates must be fresher than 0.5 seconds. Invalid numbers, older responses, worker failures and missing feeds cannot produce a valid directional scene. Faults mute directional cues and announce unavailable guidance. These are engineering cutoffs, not a guarantee of timely or correct obstacle detection.

The manually set walking yaw defines a straight walking segment. AirPods supply head orientation, not body heading or walking intent. Turning more than 50° away pauses guidance because the walking corridor is no longer covered adequately. The user must face the intended new direction and set forward before turning to walk. Pitch changes beyond 12° from calibration pause geometry-based guidance. This first demo does not infer turns or dynamically compensate camera pitch/roll.

## Estimated geometry and item continuity

Camera FOV, mount pitch, height above floor and a multiplicative depth scale are editable per feed. Defaults are placeholders to replace with measured/calibrated values. The depth model predicts optical-axis depth; pinhole projection and mount pitch yield estimated floor-relative points. Tile-supported occupancy above 0.12 m and below 2.2 m provides class-independent obstacle candidates. This avoids making safety alerts depend solely on a limited set of object labels. It does not establish walkability or detect holes, stairs, transparent surfaces, moving hazards or all thin objects.

An item's box samples its central depth region, avoiding a few background pixels. The first matching instance is chosen by detector score, then constrained by feed, bearing and range continuity. This is an approximate association, not person-specific recognition or robust tracking through occlusion. “My backpack” identifies a category; it does not establish ownership. If the chosen instance disappears or moves outside the association window, its cue stops. Find again explicitly to select another candidate. No automatic arrival or physical reach confirmation is inferred from RGB estimates.

Cancel search returns to obstacle monitoring. Voice requires an explicit enable action, the wake phrase and a completed utterance. Unavailable on-device speech has no network fallback; the manual Find field remains available. Cancellation stops item search, not obstacle monitoring. Stop guidance stops both cameras, worker and directional audio. Disable voice separately stops microphone capture.

## Validation boundary

Automated checks cover timing, priority, coordinate signs, command parsing, depth geometry, pipe integration, actual HRTF rendering and signed app construction. Synthetic depth and fixture detections verify software behavior only. A real cached-model inference smoke check establishes that the ML path runs; it does not establish white-cane detection accuracy or real-world navigation performance. Hardware acceptance requires the actual cap, both cameras, AirPods and supervised obstacle/item trials.
