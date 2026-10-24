"""Experimental sparse RGB/depth landmark memory, not a metric survey or route planner.

ORB matches + geometric RANSAC estimate pose against stored 3D landmarks.
Map geometry originates from monocular depth estimates and remains uncertain.
"""
import math
import time
import uuid
import cv2
import numpy as np
from mapping_store import LandmarkMap, MapStore, MAX_POINTS, MAX_TRAJECTORY, utc
from floorplan import integrate_floorplan
from geometry import tilt_matrix


def intrinsics(width, height, hfov):
    focal = width / (2 * math.tan(math.radians(hfov / 2)))
    return np.array([[focal, 0, width / 2 - .5], [0, focal, height / 2 - .5], [0, 0, 1]], np.float64)


def initial_pose(geometry, tilt=None):
    pitch = math.radians(geometry["pitch"])
    c, s = math.cos(pitch), math.sin(pitch)
    pose = np.eye(4)
    # Optical camera +X right/+Y down/+Z forward -> map +X right/+Y up/-Z forward.
    pose[:3, :3] = [[1, 0, 0], [0, -c, -s], [0, s, -c]]
    pose[:3, :3] = tilt_matrix(tilt) @ pose[:3, :3]
    pose[1, 3] = geometry["height"]
    return pose


def rotation_difference(a, b):
    return math.degrees(math.acos(float(np.clip((np.trace(a[:3, :3].T @ b[:3, :3]) - 1) / 2, -1, 1))))


def extract(image, depth, geometry, boxes=(), semantic=None):
    rgb = np.asarray(image)
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    h, w = gray.shape
    mask = np.full((h, w), 255, np.uint8)
    if semantic is not None:
        mask[semantic["dynamic"]] = 0
    for box in boxes:
        left, top, right, bottom = np.clip(box, 0, 1)
        cv2.rectangle(mask, (int(left*w), int(top*h)), (int(right*w), int(bottom*h)), 0, -1)
    keypoints, descriptors = cv2.ORB_create(nfeatures=900, fastThreshold=14).detectAndCompute(gray, mask)
    if descriptors is None:
        return np.empty((0, 2)), np.empty((0, 32), np.uint8), np.empty(0)
    pixels = np.array([point.pt for point in keypoints], np.float64)
    samples = []
    scaled = np.asarray(depth) * geometry["scale"]
    for u, v in pixels:
        x, y = int(round(u)), int(round(v))
        patch = scaled[max(0,y-1):y+2, max(0,x-1):x+2]
        valid = patch[np.isfinite(patch) & (patch > .3) & (patch < 8)]
        d = float(np.median(valid)) if valid.size >= 5 else float("nan")
        samples.append(d if valid.size and np.ptp(valid) < max(.12, d*.2) else float("nan"))
    samples = np.asarray(samples)
    valid = np.isfinite(samples)
    return pixels[valid], descriptors[valid], samples[valid]


def estimate_pose(memory, pixels, descriptors, camera, depths, confirmed_only=False):
    if len(descriptors) < 30 or len(memory.points) < 30:
        return None
    indices = np.flatnonzero(memory.seen >= 2) if confirmed_only else np.arange(len(memory.points))
    if len(indices) < 30:
        return None
    matches = cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(descriptors, memory.descriptors[indices], k=2)
    unique = {}
    for pair in matches:
        if len(pair) != 2:
            continue
        a, b = pair
        if a.distance <= 55 and a.distance < .72 * b.distance:
            if a.trainIdx not in unique or a.distance < unique[a.trainIdx].distance:
                unique[a.trainIdx] = a
    good = list(unique.values())
    if len(good) < 30:
        return None
    query = np.array([m.queryIdx for m in good])
    train = indices[[m.trainIdx for m in good]]
    world, image = memory.points[train], pixels[query]
    ok, rvec, tvec, inliers = cv2.solvePnPRansac(world, image, camera, None, iterationsCount=120,
        reprojectionError=2.5, confidence=.999, flags=cv2.SOLVEPNP_EPNP)
    if not ok or inliers is None or len(inliers) < 30 or len(inliers) / len(good) < .4:
        return None
    inliers = inliers[:, 0]
    rvec, tvec = cv2.solvePnPRefineLM(world[inliers], image[inliers], camera, None, rvec, tvec)
    projected = cv2.projectPoints(world[inliers], rvec, tvec, camera, None)[0].reshape(-1, 2)
    errors = np.linalg.norm(projected-image[inliers], axis=1)
    if np.median(errors) > 1.8 or np.quantile(errors, .95) > 3:
        return None
    width, height = 2 * (camera[0, 2]+.5), 2 * (camera[1, 2]+.5)
    uv = image[inliers] / [width, height]
    area = np.prod(np.ptp(uv, axis=0))
    cells = {(int(min(.999,u)*4), int(min(.999,v)*3)) for u, v in uv}
    if area < .12 or len(cells) < 6:
        return None
    rotation = cv2.Rodrigues(rvec)[0]
    camera_points = np.einsum('ij,kj->ik',world[inliers],rotation) + tvec.reshape(3)
    z = camera_points[:, 2]
    if np.any(z <= .1) or np.any(z >= 25):
        return None
    # Estimated depth is not independent evidence, but rejects gross scale/place aliases.
    ratios = np.abs(np.log(z / depths[query[inliers]]))
    if np.median(ratios) > .35 or np.quantile(ratios, .9) > .7:
        return None
    pose = np.eye(4); pose[:3, :3] = rotation.T; pose[:3, 3] = -rotation.T @ tvec.reshape(3)
    if not np.isfinite(pose).all() or abs(pose[1, 3] - memory.camera["mount"]["height"]) > 1:
        return None
    return dict(pose=pose, count=len(inliers), error=float(np.median(errors)),
                train=train[inliers], query=query[inliers], matched_queries=query)


class RoomMapper:
    def __init__(self, root, source):
        cv2.setNumThreads(1)
        self.store = MapStore(root)
        memories, self.warnings = self.store.load()
        self.maps = {memory.id: memory for memory in memories if memory.source == source}
        self.source = source
        self.active = None
        self.pose = None
        self.pending = None
        self.pending_count = 0
        self.pending_pose = None
        self.last_time = 0
        self.last_pose_time = 0
        self.failures = 0
        self.session = str(uuid.uuid4())
        self.segment = 0
        self.path = []
        self.last_save = 0
        self.persistence_error = None
        self.dirty = set()

    def _add_points(self, memory, pixels, descriptors, depths, camera, pose, excluded=()):
        candidates = np.setdiff1d(np.arange(len(pixels)), excluded)[:min(200, MAX_POINTS-len(memory.points))]
        if not len(candidates):
            return
        rays = np.einsum('ij,kj->ik',np.column_stack([pixels[candidates], np.ones(len(candidates))]),np.linalg.inv(camera))
        points = np.einsum('ij,kj->ik',rays * depths[candidates,None],pose[:3,:3]) + pose[:3,3]
        memory.points = np.concatenate([memory.points, points])
        memory.descriptors = np.concatenate([memory.descriptors, descriptors[candidates]])
        memory.seen = np.concatenate([memory.seen, np.ones(len(candidates),np.uint16)])

    def _seed(self, pixels, descriptors, depths, camera, geometry, size, tilt=None):
        self.maps = {k:m for k,m in self.maps.items() if m.revision > 0}
        if len(self.maps) >= 32:
            del self.maps[min(self.maps,key=lambda k:self.maps[k].created)] # Unload only; preserve its file.
        memory = LandmarkMap(camera=dict(imageSize=list(size), mount=dict(geometry)), source=self.source)
        pose = initial_pose(geometry, tilt)
        self._add_points(memory, pixels, descriptors, depths, camera, pose)
        memory.keyframes.append(pose.tolist())
        self.maps[memory.id] = memory
        self.active = memory.id
        self.pose = None; self.path = []; self.segment += 1
        self.pending = None; self.pending_count = 0; self.failures = 0

    def snapshot(self, status, captured, result=None, detail=""):
        memory = self.maps.get(self.active)
        return dict(status=status, updated=captured, mapID=self.active,
            landmarks=len(memory.points) if memory else 0,
            confirmed=int(np.sum(memory.seen >= 2)) if memory else 0,
            savedMaps=sum(m.revision > 0 for m in self.maps.values()),
            keyframes=len(memory.keyframes) if memory else 0,
            position=self.pose[:3,3].tolist() if self.pose is not None else None,
            heading=self.pose[:3,2].tolist() if self.pose is not None else None,
            points=memory.points[::max(1,math.ceil(len(memory.points)/500))].tolist() if memory else [],
            path=self.path[-160:], inliers=result["count"] if result else 0,
            errorPX=result["error"] if result else None, units="estimated_meters",
            resolution=.15, floor=memory.floorplan["floor"] if memory else [],
            occupied=memory.floorplan["occupied"] if memory else [],
            walls=[dict(start=w["start"],end=w["end"],observations=w["observations"]) for w in memory.floorplan["walls"]] if memory else [],
            detail=self.persistence_error or detail or ("Some saved maps could not be loaded" if self.warnings else "Sparse estimated geometry; live alerts remain independent"))

    def update(self, image, depth, geometry, captured, boxes=(), semantic=None, tilt=None):
        if captured <= self.last_time:
            return None
        self.last_time = captured
        pixels, descriptors, depths = extract(image, depth, geometry, boxes,semantic)
        camera = intrinsics(image.width, image.height, geometry["hfov"])
        if len(pixels) < 60:
            self._lost()
            return self.snapshot("insufficient_features", captured, detail="Not enough stable visual detail; live alerts continue")
        candidates = []
        for identity, memory in self.maps.items():
            if memory.camera != dict(imageSize=list(image.size),mount=dict(geometry)):
                continue # Calibration changes require a new local coordinate map.
            result = estimate_pose(memory, pixels, descriptors, camera, depths,
                confirmed_only=memory.revision > 0 and (identity != self.active or self.pose is None))
            if result is not None:
                candidates.append((identity, result))
        candidates.sort(key=lambda item:item[1]["count"], reverse=True)
        if len(candidates) > 1 and candidates[0][1]["count"] < candidates[1][1]["count"] * 1.25:
            self._lost()
            return self.snapshot("ambiguous", captured, detail="Multiple maps match; no room pose accepted")
        if not candidates:
            self._lost(); self.failures += 1
            if self.failures >= 3 or not self.maps:
                self._seed(pixels, descriptors, depths, camera, geometry, image.size, tilt)
                return self.snapshot("initializing",captured,detail="Building a new local map; geometry is provisional")
            return self.snapshot("relocalizing",captured,detail="Looking for a saved place; no map pose accepted")
        identity, result = candidates[0]
        pose = result["pose"]
        previous = self.pose if identity == self.active else None
        if previous is not None:
            dt = captured-self.last_pose_time
            if np.linalg.norm(pose[:3,3]-previous[:3,3]) > .25+2*dt or rotation_difference(pose,previous) > 25+180*dt:
                self._lost()
                return self.snapshot("lost",captured,detail="Pose jump rejected; no map extension")
        else:
            consistent = self.pending == identity and self.pending_pose is not None and np.linalg.norm(pose[:3,3]-self.pending_pose[:3,3]) < 1 and rotation_difference(pose,self.pending_pose) < 50
            self.pending_count = self.pending_count+1 if consistent else 1
            self.pending = identity; self.pending_pose = pose
            if self.pending_count < 2:
                return self.snapshot("confirming",captured,result,detail="Confirming a geometric place match across frames")
        reused = identity != self.active or self.maps[identity].revision > 0 and previous is None
        if previous is None:
            self.segment += 1; self.path = []
        self.active = identity; self.pose = pose; self.last_pose_time = captured; self.failures = 0
        memory = self.maps[identity]
        integrate_floorplan(memory.floorplan,depth,geometry,camera,pose,semantic)
        memory.seen[result["train"]] = np.minimum(65535, memory.seen[result["train"]].astype(np.uint32)+1).astype(np.uint16)
        last_key = np.asarray(memory.keyframes[-1])
        if len(memory.keyframes) < 64 and (np.linalg.norm(pose[:3,3]-last_key[:3,3]) > .25 or rotation_difference(pose,last_key) > 15):
            self._add_points(memory,pixels,descriptors,depths,camera,pose,result["matched_queries"])
            memory.keyframes.append(pose.tolist())
        position = pose[:3,3].tolist()
        if not self.path or np.linalg.norm(np.array(position)-self.path[-1]) > .03:
            self.path.append(position)
            self.path = self.path[-160:]
            if len(memory.trajectory) < MAX_TRAJECTORY:
                memory.trajectory.append(dict(segment=f"{self.session}:{self.segment}",position=position,atUTC=utc()))
        self.dirty.add(identity)
        if memory.revision == 0 or time.monotonic()-self.last_save > 3:
            self.flush()
        return self.snapshot("relocalized" if reused else "tracking",captured,result)

    def _lost(self):
        self.pose = None; self.path = []; self.pending = None; self.pending_count = 0

    def flush(self):
        for identity in list(self.dirty):
            memory = self.maps[identity]
            if np.sum(memory.seen >= 2) < 30:
                continue
            try:
                self.store.save(memory)
                self.dirty.discard(identity)
                self.persistence_error = None
            except (ValueError, OSError) as exc:
                self.persistence_error = "Map persistence unavailable: " + str(exc)
        self.last_save = time.monotonic()
