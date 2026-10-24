"""Versioned local map storage. No images, pickle, absolute room registration or cloud dependency."""
import base64
from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import tempfile
import uuid
import fcntl
import numpy as np

SCHEMA = "seear-room-map-v1"
MAX_POINTS = 3000
MAX_TRAJECTORY = 1000
MAX_FILE_BYTES = 4_000_000


def utc():
    return datetime.now(timezone.utc).isoformat()


def finite_array(value, shape):
    array = np.asarray(value, dtype=np.float64)
    if array.shape != shape or not np.isfinite(array).all():
        raise ValueError("Invalid or non-finite map geometry")
    return array


@dataclass
class LandmarkMap:
    camera: dict
    source: dict
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    created: str = field(default_factory=utc)
    points: np.ndarray = field(default_factory=lambda: np.empty((0, 3), np.float64))
    descriptors: np.ndarray = field(default_factory=lambda: np.empty((0, 32), np.uint8))
    seen: np.ndarray = field(default_factory=lambda: np.empty(0, np.uint16))
    keyframes: list = field(default_factory=list)
    trajectory: list = field(default_factory=list)
    extensions: dict = field(default_factory=dict)
    revision: int = 0
    floorplan: dict = field(default_factory=lambda:dict(resolution=.15,floor=[],occupied=[],walls=[],partial=True))

    def document(self):
        return dict(schema=SCHEMA, id=self.id, revision=self.revision, createdUTC=self.created, updatedUTC=utc(),
                    coordinates="x-right-y-up-z-back", geometrySource=self.source, camera=self.camera,
                    registration=dict(status="local", frameID=self.id),
                    points=self.points.tolist(),
                    descriptors=base64.b64encode(self.descriptors.tobytes()).decode("ascii"),
                    observations=self.seen.tolist(), keyframes=self.keyframes,
                    trajectory=self.trajectory, floorplan=self.floorplan, extensions=self.extensions)

    @classmethod
    def from_document(cls, value):
        if value.get("schema") != SCHEMA or value.get("coordinates") != "x-right-y-up-z-back":
            raise ValueError("Unsupported map version or coordinates")
        identity = str(uuid.UUID(value["id"]))
        if not isinstance(value["createdUTC"],str) or not value["createdUTC"]:
            raise ValueError("Invalid creation timestamp")
        registration = value["registration"]
        if registration != dict(status="local", frameID=identity):
            raise ValueError("Unsupported map registration")
        source, camera = value["geometrySource"], value["camera"]
        if not isinstance(camera, dict) or not isinstance(source, dict):
            raise ValueError("Invalid map metadata")
        if source.get("kind") != "monocular_estimate" or source.get("units") != "estimated_meters":
            raise ValueError("This mapper only localizes its estimated RGB maps; phone scans need a registration adapter")
        mount = camera["mount"]
        for key, low, high in [("hfov",20,140),("pitch",-30,85),("height",.5,2.5),("scale",.1,5)]:
            if not isinstance(mount[key], (int,float)) or not low <= mount[key] <= high:
                raise ValueError("Invalid saved camera geometry")
        size = camera["imageSize"]
        if len(size) != 2 or any(not isinstance(v,int) or not 1 <= v <= 1280 for v in size):
            raise ValueError("Invalid saved camera size")
        revision = value["revision"]
        if not isinstance(revision,int) or revision < 0:
            raise ValueError("Invalid map revision")
        points = np.asarray(value["points"], dtype=np.float64)
        if not 30 <= len(points) <= MAX_POINTS:
            raise ValueError("Invalid landmark count")
        finite_array(points, (len(points), 3))
        if np.any(np.abs(points) > 1000):
            raise ValueError("Map geometry exceeds extent limit")
        raw = base64.b64decode(value["descriptors"], validate=True)
        if len(raw) != len(points) * 32:
            raise ValueError("Invalid descriptor array")
        counts = np.asarray(value["observations"], dtype=np.float64)
        if counts.shape != (len(points),) or not np.isfinite(counts).all() or np.any((counts < 1) | (counts > 65535)):
            raise ValueError("Invalid observation counts")
        if not np.equal(counts, np.floor(counts)).all():
            raise ValueError("Non-integer observation counts")
        keyframes = value["keyframes"]
        if not isinstance(keyframes, list) or not 1 <= len(keyframes) <= 64:
            raise ValueError("Invalid keyframes")
        for pose in keyframes:
            pose = finite_array(pose, (4, 4))
            if not np.allclose(pose[3], [0, 0, 0, 1]) or not np.allclose(pose[:3, :3].T @ pose[:3, :3], np.eye(3), atol=1e-3) or np.linalg.det(pose[:3, :3]) < .99:
                raise ValueError("Invalid rigid pose")
        trajectory = value["trajectory"]
        if not isinstance(trajectory, list) or len(trajectory) > MAX_TRAJECTORY:
            raise ValueError("Invalid trajectory")
        for step in trajectory:
            finite_array(step["position"], (3,))
            if not isinstance(step["segment"], str):
                raise ValueError("Invalid trajectory segment")
        extensions = value.get("extensions", {})
        if not isinstance(extensions, dict):
            raise ValueError("Invalid map extensions")
        plan = value["floorplan"]
        if not isinstance(plan,dict) or plan.get("resolution") != .15 or plan.get("partial") is not True:
            raise ValueError("Unsupported floorplan grid or completeness claim")
        for kind in ("floor","occupied"):
            if not isinstance(plan[kind],list) or len(plan[kind]) > 6000:
                raise ValueError("Invalid floorplan grid")
            for cell in plan[kind]:
                if len(cell) != 3 or not all(isinstance(v,int) for v in cell) or max(abs(cell[0]),abs(cell[1])) >= 2048 or not 1 <= cell[2] <= 65535:
                    raise ValueError("Invalid floorplan cell")
        if not isinstance(plan["walls"],list) or len(plan["walls"]) > 32:
            raise ValueError("Too many wall segments")
        for wall in plan["walls"]:
            a,b = finite_array(wall["start"],(2,)),finite_array(wall["end"],(2,))
            if np.linalg.norm(b-a) < .5 or np.max(np.abs([a,b])) > 1000:
                raise ValueError("Invalid wall segment")
            if not isinstance(wall["observations"],int) or not 1 <= wall["observations"] <= 65535 or not 0 <= wall["error"] <= 1:
                raise ValueError("Invalid wall evidence")
            finite_array(wall["lastPosition"],(3,)); finite_array(wall["lastForward"],(3,))
        return cls(camera=camera, source=source, id=identity, created=value["createdUTC"],
                   points=points, descriptors=np.frombuffer(raw, np.uint8).reshape(-1, 32).copy(),
                   seen=counts.astype(np.uint16), keyframes=keyframes, trajectory=trajectory, extensions=extensions, revision=revision, floorplan=plan)


class MapStore:
    def __init__(self, root):
        self.root = Path(root)

    def load(self):
        maps, errors = [], []
        if not self.root.exists():
            return maps, errors
        # Bound startup work, preserve every file, and never delete older memories.
        for path in sorted(self.root.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)[:32]:
            try:
                if path.stat().st_size > MAX_FILE_BYTES:
                    raise ValueError("Map file exceeds size limit")
                memory = LandmarkMap.from_document(json.loads(path.read_text()))
                if path.stem != memory.id:
                    raise ValueError("Map filename does not match its identifier")
                maps.append(memory)
            except (ValueError, KeyError, TypeError, OSError, AttributeError, RecursionError, OverflowError) as exc:
                errors.append(f"{path.name}: {exc}")
        return maps, errors

    def save(self, memory):
        # Validate our own snapshot too, so a bad numeric estimate cannot corrupt a saved map.
        self.root.mkdir(parents=True, exist_ok=True)
        with (self.root / ".map-write.lock").open("a+b") as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            destination = self.root / (str(uuid.UUID(memory.id)) + ".json")
            if destination.exists():
                existing = json.loads(destination.read_text())
                if not isinstance(existing,dict) or existing.get("revision") != memory.revision:
                    raise ValueError("Map changed in another session; refusing to overwrite it")
            elif memory.revision != 0:
                raise ValueError("Previously saved map is missing; refusing to recreate it silently")
            document = memory.document(); document["revision"] = memory.revision+1
            LandmarkMap.from_document(document)
            data = json.dumps(document, allow_nan=False, separators=(",", ":")).encode("utf-8")
            if len(data) > MAX_FILE_BYTES:
                raise ValueError("Map snapshot exceeds size limit")
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=self.root, prefix=".map-", suffix=".tmp", delete=False) as stream:
                    temporary = Path(stream.name)
                    stream.write(data); stream.flush(); os.fsync(stream.fileno())
                os.replace(temporary,destination)
                memory.revision += 1
            finally:
                if temporary is not None and temporary.exists():
                    temporary.unlink()
