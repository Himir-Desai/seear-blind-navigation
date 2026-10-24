# Bug ledger

| Identifier | Description | Related feature | Fixed |
| --- | --- | --- | --- |
| B1 | Initial full-precision OWLv2 inference could not sustain the two-camera freshness budget during item search. Use MPS half precision for the detector and warm the model before accepting frames; retain the 1.5 s cutoff. | 1 | Yes — eight alternating native→model→native frames passed; mean 446 ms, maximum oldest-frame age before/after replies 1.365 s. Real camera performance still requires acceptance. |
| B2 | Callback-time frame stamping could make a driver-buffered image appear newer than it was and pair it with a newer head yaw. Convert capture sample timestamps to the host clock and interpolate timestamped motion. | 1 | Yes — signed build and regression checks pass for capture-time freshness, seam interpolation, out-of-order samples and stalled motion. Physical camera timing still requires acceptance. |

Historical prototype limitations are recorded in `docs/PROTOTYPE_FINDINGS.md`; those prototypes are outside this repository's scope.
