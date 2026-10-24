#!/usr/bin/env python3
"""One bounded NDJSON request/reply at a time over private subprocess pipes."""
import argparse
import base64
import io
import json
import os
import sys
import time

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


def emit(value):
    print(json.dumps(value, allow_nan=False, separators=(",", ":")), flush=True)


def run(backend):
    from PIL import Image
    from geometry import scene_geometry
    emit(dict(type="ready", device=backend.device))
    for raw in sys.stdin:
        try:
            if len(raw) > 4_000_000:
                raise ValueError("Frame too large")
            request = json.loads(raw)
            start = time.monotonic()
            target = request.get("target", "")
            if not isinstance(target, str) or len(target) > 64:
                raise ValueError("Invalid target")
            if request["feed"] not in ("front", "feet"):
                raise ValueError("Invalid feed")
            image = Image.open(io.BytesIO(base64.b64decode(request["jpeg"], validate=True))).convert("RGB")
            if image.width > 1280 or image.height > 1280:
                raise ValueError("Frame dimensions exceed protocol limit")
            depth, detections = backend.infer(image, target)
            objects, obstacles, coverage = scene_geometry(depth, detections, **request["geometry"])
            scene = dict(feed=request["feed"], captured=request["captured"], yaw=request["yaw"], target=target,
                         objects=objects, obstacles=obstacles, coverage=coverage,
                         inferenceMS=(time.monotonic() - start) * 1000)
            emit(dict(type="scene", scene=scene, id=request["id"]))
        except Exception as exc:
            # An invalid frame is an error, never an empty 'clear' scene.
            emit(dict(type="error", message=str(exc)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", action="store_true", help="Synthetic integration test only; no camera inference")
    args = parser.parse_args()
    try:
        if args.fixture:
            import numpy as np
            class Fixture:
                device = "SYNTHETIC TEST"
                def infer(self, image, target):
                    return np.full((image.height, image.width), 2.0), ([dict(label=target, confidence=.9, box=[.3,.3,.7,.7])] if target else [])
            run(Fixture())
        else:
            from backend import LocalVision
            run(LocalVision())
    except Exception as exc:
        emit(dict(type="error", message="Local vision unavailable: " + str(exc)))
        sys.exit(1)
