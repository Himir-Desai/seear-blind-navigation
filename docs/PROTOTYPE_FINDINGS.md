# Prototype evidence and Demo 1 choices

Reviewed 2026-10-24. Historical prototypes remain outside this repository and were not changed. Results below describe virtual tasks, not real-world obstacle avoidance or blind-user safety. Sessions do not establish population-level effects.

## What the experiments support

| Experiment | Evidence in the parent folder | Implication for Demo 1 |
| --- | --- | --- |
| P1 | Discrete directions were difficult near the centre; broadband stimuli were descriptively useful. See `Test Prototype 1/README.md` and its result CSVs. | Keep broadband energy for localization; a pure sine beep discards useful spectral information. |
| P2 | In `data/summary_20260904_153220.txt`, Original/Sharp/Hybrid mean angular errors were 4.00°/5.15°/5.18°, 15 trials per stimulus. The P2 Hybrid is a different stimulus from P4 Hybrid. | Reuse genuine Apple HRTFHQ and calibrated AirPods motion. Do not claim Original is statistically superior. |
| P3A | The parent report describes accurate final virtual positions with inefficient, correction-heavy approach paths. | Direction alone does not establish usable approach guidance; include distance feedback and measure approach performance. |
| P3B | The current README identifies two-source perception as 3B. Count detection was easier than localizing both sources. | Limit the audio scene to the requested item and the most urgent in-path obstacle. |
| P3C | `data/trials3c_20260908_223030.csv`: mean trial error 10.273° baseline (14), 6.898° spectral focus (13), 3.408° focus+lock-on (13). All recorded as experiment with tracking active. | Attention is promising, but the prior user choice excluded lock-on from P4. Do not silently restore it. |

The older `auditory_spatial_experiments_report.docx` predates the P3C pilot and P4; its statement that attention has no participant evidence is stale. It also uses an older 3B/3C naming transition. Current source, README, metadata and recorded CSVs take precedence.

## Latest completed three-system comparison

Source: `../Test Prototype 4/data/2026-09-09_22-44-12_868/`. `session.json` records `mode=experiment`, `schema_version=6`, `schedule_version=selected-systems-v3`, `hybrid_version=hybrid-2.1`, seed `14263877725858430592`, and a 120-second limit. The 12 recorded trials have valid tracking samples, zero invalid samples, and four completed scenes per system.

| P4 system | Scenes complete | Scene-weighted first-press error, including misses | Mean scene time | Mean path | Failed presses |
| --- | --- | --- | --- | --- | --- |
| Original / focus_gain | 4/4 | 0.43139 m | 58.18560 s | 22.38289 m | 3 |
| Astra 1 | 4/4 | 0.22135 m | 57.56934 s | 23.03284 m | 0 |
| Hybrid 2.1 | 4/4 | 0.17534 m | 64.61502 s | 22.51646 m | 0 |

These values were checked against `summary.txt` and the underlying trial/capture CSVs. A first press means the first attempt in each search leg, including an unsuccessful attempt; successes within 0.75 m are threshold-selected. Error is to the nearest unfound source, not a verified intended target. Each scene had three attempted legs, so the scene-weighted and pooled first-press errors happen to agree here.

Hybrid was more accurate on this descriptive measure and slower. Layouts differ by system within the run, treatments are audibly different, the sample is tiny, and participant independence is not established by run metadata. No confirmatory winner or real-world reliability follows.

Earlier sessions must remain separate. Hybrid 1 and 2 differ from 2.1; the two-scene Hybrid 2.1 run at `2026-09-09_22-31-42_630` includes a timeout. Lessons and the three short ended-early runs are not completed comparisons. Do not hide these outcomes or pool versions as an unchanged treatment. Original's inherited focus has a documented rear level residual up to +3.22 dB.

## Selected audio behavior

The **item cue** uses P4 Hybrid 2.1 as a provisional engineering baseline: mono pulsed white-noise/harmonic mixture, a shared 440 Hz timbre, HRTFHQ, distance-dependent pulse rate and explicit gain, the 45°/90°/170° angular curve, near-source exception, and 1 dB upper-harmonic forward boost. Rate is `0.65 + 5.35/(1+d/1.5)` Hz; gain is `1/d` above 1 m and `2-d` below it. Native distance rolloff is disabled to prevent double attenuation. New name: `demo-item-hybrid-2.1` because camera-driven updates are a new application, not an unchanged experiment.

The **obstacle alert** is a new demo policy, `demo-hazard-2` (B3 camera-forward correction): the same broad spatial carrier with an 880 Hz tone and a faster pulse rate, with **no FOV mute**. It represents the nearest estimated obstacle inside a 1.1 m wide, 3 m long corridor centred on the current cap-camera/head direction. It follows turns automatically and does not infer body travel direction. The earlier `demo-hazard-1` used a manually set walking heading and was replaced under B3. An obstacle within 1.2 m suppresses the item cue; a farther hazard ducks the item to 20%. These thresholds are initial engineering settings, not experimentally validated stopping distances. Alerts indicate the obstacle's location, never a command to walk toward it.

No lock-on, room simulation, experimental dashboard, object-specific identity pitches, route planning, or continuous scene narration is carried into this demo. The old frozen Original waveform is not modified or presented as this new waveform.

## Local vision sources

OWLv2 supplies text-conditioned boxes, including a literal “white cane” query rather than assuming a closed-set detector has that class. It is a research detector and its scores are not calibrated probabilities. [Model card](https://huggingface.co/google/owlv2-base-patch16-ensemble), [Transformers API](https://huggingface.co/docs/transformers/model_doc/owlv2).

Depth Anything V2 Metric Indoor Small supplies monocular depth estimates. This is the indoor metric checkpoint, not a normalized relative-depth visualization. [Publisher model card](https://huggingface.co/depth-anything/Depth-Anything-V2-Metric-Indoor-Small-hf), [original metric-depth implementation](https://github.com/DepthAnything/Depth-Anything-V2/tree/main/metric_depth).

Apple's headphone motion API requires runtime availability checks and a motion usage description. Local speech is enabled only when the recognizer reports on-device support. [Headphone motion](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager), [on-device speech availability](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition).
