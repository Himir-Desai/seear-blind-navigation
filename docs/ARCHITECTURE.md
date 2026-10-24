# Demo 1 architecture

User-confirmed scope: this Mac, two RGB USB cameras on a cap, local processing with replaceable modules, and an indoor supervised demo.

## Data flow

```text
Front USB camera ─┐                         ┌─ text-conditioned item detector
                  ├─ latest JPEG ─ Python ─┤
Feet USB camera ──┘   + capture yaw/time     └─ indoor metric monocular depth
                                                    │
AirPods motion ─ automatic reference ─ current yaw           │ NDJSON scene
                              │                     ▼
Local speech ─ wake grammar ─ target query ─ guidance engine
                                                │
                                  target + nearest in-path hazard
                                                │
                              mono pulse voices → HRTFHQ → AirPods
```

`SeearCore` contains geometry, command parsing, freshness checks, approximate target continuity, camera-forward corridor filtering, voice pause/resume and priority. It is independent of AppKit, cameras, ML and audio. `Camera` captures both USB devices using AVFoundation. `VisionWorker` sends one frame at a time over private process pipes and alternates feeds; old frames are replaced, not queued. `vision/backend.py` owns detector/depth inference; `vision/geometry.py` turns depth into observations. A different local or future cloud backend can implement `infer(image, target)` and retain the scene contract. No cloud inference or remote fallback is enabled.

The Python worker loads cached model weights only, refuses remote model code, and uses safetensors. The setup script downloads public weights and packages once. Images/audio are not recorded or uploaded. Python diagnostics go to ignored `build/vision.log`; no frame or voice-transcript logging is implemented.

## Coordinate and freshness contract

`+X` is right, `+Y` up, and `-Z` forward. Bearings are degrees clockwise from an arbitrary automatically initialized motion origin; that origin is not a walking direction. An observation's bearing is relative to its camera at capture. The front and feet camera optical axes must be aligned in yaw with the cap's forward direction. Their different downward mount angles are entered separately. FOV assumes a rectilinear, square-pixel camera; strongly distorted/wide-angle video requires rectification before use.

Each sample's presentation timestamp is converted from the capture session's synchronization clock to the host's monotonic clock. Camera frames retain that time through inference; driver-delayed buffers do not receive a new time on delivery. Capture yaw is interpolated from timestamped AirPods samples, including across the ±180° seam; missing or stalled motion history rejects the frame. The guidance engine adds capture yaw once to obtain an absolute bearing, and the HRTF listener applies current yaw once. This avoids rotating a cap-mounted camera observation twice. AirPods yaw uses the existing −1 rightward-sign convention, also recorded in P4’s `2026-09-09_22-44-12_868/calibration.csv`. The first motion sample after backend start establishes an arbitrary yaw origin and starting head pitch automatically. Normal turns never reset this origin. After a motion gap over 0.5 s, the next sample starts a new reference generation; old frames, motion history and in-flight scenes from before that generation are discarded. Left/right alignment must still be checked with the actual hardware during operator setup. macOS environmental automatic listener tracking is disabled in the audio graph.

An independent experimental mapper estimates translation and partial room geometry for saved memory/debugging; see [room mapping](ROOM_MAPPING.md). Audio does not consume this map pose. The sound source's range/position is refreshed from the latest camera estimate. Between frames, head rotation is compensated but walking translation is not. This limitation matters near an object and when latency increases.

Both feeds must have estimated depth coverage ≥60% and capture age ≤1.5 seconds, and AirPods updates must be fresher than 0.5 seconds. Invalid numbers, older responses, worker failures and missing feeds cannot produce a valid directional scene. Faults mute directional cues and announce unavailable guidance. These are engineering cutoffs, not a guarantee of timely or correct obstacle detection.

The forward alert corridor is centred on **current head/cap-camera yaw**. For every candidate, the engine computes `wrap(camera_relative_bearing + capture_yaw - current_yaw)` and checks the existing 1.1 m width and 3 m reach in that frame. Fresh images after a turn therefore define the new forward automatically. An older obstacle does not move into the new forward merely because it used to be centred. There is no walking-heading variable, 50° turn gate, Set forward command or direction-reset button.

This implements head-forward monitoring, not body-heading estimation. A sideways glance can leave the actual travel path outside the two cap cameras' coverage. AirPods and cap cameras alone do not establish walking intent. Pitch changes beyond 12° from the session's starting pitch still pause geometry-based guidance; returning to that pitch recovers without manual calibration. Dynamic pitch/roll compensation for live obstacle geometry, audio translation compensation and route planning remain outside this change.

## Estimated geometry and item continuity

Camera FOV, mount pitch, height above floor and a multiplicative depth scale are editable per feed. Defaults are placeholders to replace with measured/calibrated values. The depth model predicts optical-axis depth; pinhole projection and mount pitch yield estimated floor-relative points. Tile-supported occupancy above 0.12 m and below 2.2 m provides class-independent obstacle candidates. This avoids making safety alerts depend solely on a limited set of object labels. It does not establish walkability or detect holes, stairs, transparent surfaces, moving hazards or all thin objects.

An item's box samples its central depth region, avoiding a few background pixels. The first matching instance is chosen by detector score, then constrained by feed, bearing and range continuity. This is an approximate association, not person-specific recognition or robust tracking through occlusion. “My backpack” identifies a category; it does not establish ownership. If the chosen instance disappears or moves outside the association window, its cue stops. Find again explicitly to select another candidate. No automatic arrival or physical reach confirmation is inferred from RGB estimates.

Cancel search returns to obstacle monitoring. Voice starts automatically with backend startup and requires the wake phrase and a completed utterance. On-device speech or microphone setup failures are spoken, with no network fallback; the manual Find field is a supervisor debug override, not the wearer’s fallback interface. Cancellation stops item search, not obstacle monitoring. Voice pause mutes directional guidance and suspends new inference requests while keeping the microphone active. Resume retains the search query, clears old scenes and requires fresh camera results. The supervisor’s Stop backend control stops both cameras, worker and directional audio; voice remains available for a spoken restart using the configured devices. Disable voice is a separate debug override that stops microphone capture.

## Validation boundary

Automated checks cover timing, priority, coordinate signs, command parsing, depth geometry, pipe integration, actual HRTF rendering and signed app construction. Synthetic depth and fixture detections verify software behavior only. A real cached-model inference smoke check establishes that the ML path runs; it does not establish white-cane detection accuracy or real-world navigation performance. Hardware acceptance requires the actual cap, both cameras, AirPods and supervised obstacle/item trials.
