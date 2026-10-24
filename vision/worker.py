#!/usr/bin/env python3
"""One bounded NDJSON request/reply at a time over private subprocess pipes."""
import argparse
import base64
import io
import json
import os
import sys
import time
import threading

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


output_lock = threading.Lock()


def emit(value):
    line = json.dumps(value, allow_nan=False, separators=(",", ":"))
    with output_lock:
        print(line,flush=True)


def run(backend, mapping=False):
    from PIL import Image
    from geometry import scene_geometry
    service = None
    if mapping:
        try:
            from mapping_service import MappingService
            from backend import DEPTH, SEGMENTATION, REVISIONS
            source = dict(kind="monocular_estimate",units="estimated_meters",model=DEPTH,
                          revision=REVISIONS[DEPTH],segmentation=SEGMENTATION,segmentationRevision=REVISIONS[SEGMENTATION],
                          algorithm="depth-assisted-landmarks-floorplan-v1")
            service = MappingService(emit,source)
        except Exception as exc:
            emit(dict(type="map_error",message="Room memory unavailable: " + str(exc)))
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
            excluded,filter_info = None,None
            if request["feed"] == "feet" and callable(getattr(backend,"infer_wearer",None)):
                from wearer import wearer_mask
                depth,detections,body = backend.infer_wearer(image,target)
                excluded,filter_info = wearer_mask(image,depth,body,"feet",request["geometry"])
            else:
                depth,detections = backend.infer(image,target)
            objects, obstacles, coverage = scene_geometry(depth, detections, excluded=excluded,**request["geometry"])
            scene = dict(feed=request["feed"], captured=request["captured"], yaw=request["yaw"], target=target,
                         objects=objects, obstacles=obstacles, coverage=coverage,
                         inferenceMS=(time.monotonic() - start) * 1000,wearerFilter=filter_info)
            emit(dict(type="scene", scene=scene, id=request["id"]))
            if service is not None:
                try:
                    service.submit(image,depth,request,objects)
                except Exception as exc:
                    service.disabled = True
                    emit(dict(type="map_error",message="Room memory unavailable: " + str(exc)))
        except Exception as exc:
            # An invalid frame is an error, never an empty 'clear' scene.
            emit(dict(type="error", message=str(exc)))
    if service is not None:
        service.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", action="store_true", help="Synthetic integration test only; no camera inference")
    parser.add_argument("--no-mapping", action="store_true", help="Run live navigation without local room memory")
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
            run(LocalVision(),mapping=not args.no_mapping)
    except Exception as exc:
        emit(dict(type="error", message="Local vision unavailable: " + str(exc)))
        sys.exit(1)
