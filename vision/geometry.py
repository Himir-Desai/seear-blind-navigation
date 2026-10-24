"""RGB-derived geometry. All distances are estimates, never sensor measurements."""
import math
import numpy as np


def tilt_matrix(tilt=None):
    if tilt is None:
        return np.eye(3)
    rotation = np.asarray(tilt, dtype=float)
    if rotation.size != 9:
        raise ValueError("Invalid capture tilt")
    rotation = rotation.reshape(3, 3)
    if (not np.isfinite(rotation).all() or
            not np.allclose(rotation.T @ rotation, np.eye(3), atol=1e-5) or
            abs(np.linalg.det(rotation)-1) > 1e-5):
        raise ValueError("Invalid capture tilt")
    return rotation


def project(depth, hfov, pitch, height, tilt=None):
    h, w = depth.shape
    if not (20 <= hfov <= 140 and -30 <= pitch <= 90 and 0.5 <= height <= 2.5):
        raise ValueError("Invalid camera geometry")
    focal = w / (2 * math.tan(math.radians(hfov / 2)))
    # Compose the mount and dynamic attitude before projecting. Broadcast 1-D
    # ray coordinates rather than rotating several full-resolution point arrays.
    # This keeps per-frame tilt compensation inside the live freshness budget.
    horizontal = (np.arange(w)[None, :] + 0.5 - w / 2) / focal
    down = (np.arange(h)[:, None] + 0.5 - h / 2) / focal
    p = math.radians(pitch)
    c, s = math.cos(p), math.sin(p)
    r = tilt_matrix(tilt) @ np.array([[1,0,0],[0,-c,-s],[0,s,-c]])
    return ((r[0,0]*horizontal + r[0,1]*down + r[0,2])*depth,
            -(r[2,0]*horizontal + r[2,1]*down + r[2,2])*depth,
            height + (r[1,0]*horizontal + r[1,1]*down + r[1,2])*depth)


def observation(label, confidence, x, forward, vertical, height, box=None):
    horizontal = math.hypot(float(x), float(forward))
    return dict(label=label, confidence=float(confidence),
                bearing=math.degrees(math.atan2(float(x), float(forward))),
                elevation=math.degrees(math.atan2(float(vertical) - height, horizontal)),
                distance=horizontal, box=box or [])


def scene_geometry(depth, detections, hfov=70, pitch=0, height=1.6, scale=1, excluded=None, tilt=None):
    if not 0.1 <= scale <= 5:
        raise ValueError("Depth scale must be between 0.1 and 5")
    depth = np.asarray(depth, dtype=np.float32) * scale
    valid = np.isfinite(depth) & (depth > 0.05) & (depth < 30)
    coverage = float(valid.mean())
    x, forward, vertical = project(depth, hfov, pitch, height, tilt)
    h, w = depth.shape
    objects, obstacles = [], []
    for detection in detections:
        box = np.clip(detection["box"], 0, 1).tolist()
        # Sample centre of a box to reduce background contamination.
        left, top, right, bottom = box
        x0, x1 = int((left * .75 + right * .25) * w), max(1, int((left * .25 + right * .75) * w))
        y0, y1 = int((top * .75 + bottom * .25) * h), max(1, int((top * .25 + bottom * .75) * h))
        roi = valid[y0:y1, x0:x1]
        if not roi.size or roi.mean() < .6:
            continue
        # Median of projected positions is robust to a few depth outliers.
        coords = [float(np.median(a[y0:y1, x0:x1][roi])) for a in (x, forward, vertical)]
        if math.hypot(*coords[:2]) > .05:
            objects.append(observation(detection["label"], detection["confidence"], *coords, height, box))

    # Class-independent occupancy: a miss by the object detector must not hide a chair/wall.
    # Exclude estimated floor and points above head height. RGB errors can still create
    # false positives/negatives; this is not a drop-off or walkable-space detector.
    occupied = valid & (vertical > .12) & (vertical < 2.2) & (forward > .1) & (forward < 4)
    if excluded is not None:
        excluded = np.asarray(excluded)
        if excluded.shape != occupied.shape or excluded.dtype != bool:
            raise ValueError("Invalid wearer exclusion mask")
        occupied &= ~excluded
    for row in range(6):
        for col in range(12):
            ys = slice(row * h // 6, (row + 1) * h // 6)
            xs = slice(col * w // 12, (col + 1) * w // 12)
            mask = occupied[ys, xs]
            if mask.sum() < max(8, mask.size * .18):
                continue
            distances = np.hypot(x[ys, xs][mask], forward[ys, xs][mask])
            # A lower quantile preserves the near edge without trusting one hot pixel.
            near = distances <= np.quantile(distances, .25)
            coords = [float(np.median(a[ys, xs][mask][near])) for a in (x, forward, vertical)]
            obstacles.append(observation("obstacle", 1, *coords, height))
    return objects, obstacles, coverage
