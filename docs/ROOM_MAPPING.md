# Experimental room memory and partial floorplan

Feature 2 runs entirely on the Mac. With **Build room memory** enabled during backend setup (the default), front-camera observations build local maps automatically. **Room map (debug)** opens a top-down view. There are no wearer mapping buttons or manual forward resets. The feet feed continues obstacle detection; it is not treated as a calibrated stereo pair. No existing map, phone, scan or network connection is required for live guidance.

The implementation saves visual landmarks, estimated camera poses and observed floor/wall geometry. Returning to a saved visual region can recover its coordinate frame after geometric verification. A local map may span multiple rooms or split into separate maps after tracking loss; it does not identify named rooms. This is depth-assisted sparse visual mapping, with no global bundle adjustment, loop correction, map merging or route planning. Drift and false recognition remain possible.

## How a map is built

1. ORB descriptors find visual features outside detected target boxes and semantic dynamic-object masks. Features need supported, reasonably consistent estimated depth between 0.3 and 8 m.
2. Binary descriptor matching and a ratio test propose correspondences to saved 3D landmarks. PnP RANSAC and refinement require at least 30 inliers, spatial image coverage, low reprojection error, positive depth and depth-scale consistency. Saved-place recovery needs two consistent frames; ambiguous place matches are rejected. Pose jumps are rejected during tracking.
3. Accepted poses extend the map at translation/rotation keyframes. Tracking loss removes the current pose and stops geometric extension. Three unmatched feature-rich frames can seed a separate local map. Blank or texture-poor images cannot establish a map.
4. A local SegFormer wall/floor segmentation model runs on CPU in a background thread. Only accepted poses accumulate its depth-projected observations. Vertical RANSAC planes supported by wall-labelled pixels produce wall segments. Three distinct viewpoints turn a dashed wall candidate into a solid repeated estimate. The 15 cm grid records observed floor and occupied surfaces; those cells are not certified walkable space.

The debug view shows blank space for unseen areas. It never forces a closed room outline, invents hidden walls or assumes a doorway. Wall estimates can still include misclassified furniture. Glass, mirrors, textureless walls, moving objects, lighting changes and occlusion can defeat both depth and localization. Multiple views are supporting evidence, not a measurement-accuracy guarantee.

Live item and obstacle cues continue to use fresh camera observations and AirPods rotation. They do not use saved walls to declare a path clear or guide around an unseen corner. Estimated map translation does not compensate audio between camera frames. Map failure has its own status and does not invalidate a valid live scene. Background processing uses a latest-frame mailbox of one; it drops older pending map work. Resource contention can still slow inference, so live freshness cutoffs remain enforced.

## Persistence and reuse

Maps are ignored local files in `data/maps/<UUID>.json` (`SEEAR_MAPS` overrides the folder). No RGB frames or audio are saved. Descriptors, geometry and visited positions still reveal information about the environment; treat map files as private data. Stop the backend before manually moving/removing files.

`seear-room-map-v1` records coordinate convention (+X right, +Y up, −Z initial forward), model revisions, estimated units, camera calibration, landmark descriptors/observation counts, keyframe poses, segmented trajectory, floor cells and wall evidence. Writes use a temporary file plus atomic replacement, an exclusive lock and revision conflict checks. Invalid/unsupported files are skipped and preserved. Startup loads at most 32 maps; each map caps landmarks at 3,000, keyframes at 64, trajectory samples at 1,000, each grid at 6,000 cells and wall segments at 32. Reaching a cap limits further growth; it is not proof that coverage is complete.

Reuse requires matching model provenance and camera settings/image dimensions. Calibrating FOV, mount pitch, cap height and depth scale matters: pinhole intrinsics and a fixed mount cannot remove lens distortion or monocular scale errors. Saved geometry may become stale if furniture moves. No metric accuracy or full floorplan completeness has been established with physical cap cameras.

## Optional phone scans later

An optional future iPhone LiDAR companion can provide better room geometry. It must export a versioned geometry source with measured units, uncertainty, coordinate frame and explicit registration to the live cap-camera map. Phone geometry alone cannot establish where the cap is now; shared visual landmarks or another validated registration method are still required. The current reader intentionally rejects unregistered LiDAR documents. Apple RoomPlan/ARWorldMap/USDZ are not automatically interchangeable with the Mac's USB-camera frame. No iPhone app or scan importer is included in this iteration.

## Models, license and references

The new cached model is `nvidia/segformer-b0-finetuned-ade-512-512`, pinned in `vision/backend.py`. Its model card links the NVIDIA Source Code License, whose §3.3 restricts use to noncommercial research/evaluation. This supervised research demo does not distribute model weights; check license compatibility before any broader use. Detector/depth provenance remains in the prototype/architecture documents.

Primary references: [OpenCV feature matching](https://docs.opencv.org/4.x/dc/dc3/tutorial_py_matcher.html), [OpenCV PnP](https://docs.opencv.org/4.x/d5/d1f/calib3d_solvePnP.html), [SegFormer model card](https://huggingface.co/nvidia/segformer-b0-finetuned-ade-512-512), [NVIDIA license](https://github.com/NVlabs/SegFormer/blob/master/LICENSE), [Apple RoomPlan](https://developer.apple.com/augmented-reality/roomplan/), [shared room coordinate systems](https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure) and [ARWorldMap](https://developer.apple.com/documentation/arkit/arworldmap).

B6 seeds new map coordinates with gravity-aligned capture tilt, including when mapping starts with a tilted head. Subsequent landmark poses already estimate all six degrees of freedom; dynamic tilt is not applied a second time during floorplan integration. Per-frame attitude stays separate from fixed camera calibration, so tilting does not cause a calibration mismatch. Mapping failures remain independent of live alerts. Provenance is now `gravity-aligned-landmarks-floorplan-v2`; earlier map files are preserved but not reused because their initial gravity alignment was not established under arbitrary tilt.
