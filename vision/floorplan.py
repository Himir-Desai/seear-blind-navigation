"""Accumulate only observed RGB-estimated surfaces; never close unknown room boundaries."""
import math
import uuid
import numpy as np

RESOLUTION = .15
MAX_CELLS = 6000


class RoomSegmentation:
    def __init__(self):
        import torch
        from transformers import AutoImageProcessor, AutoModelForSemanticSegmentation
        from backend import SEGMENTATION, REVISIONS, cache_root
        args = dict(cache_dir=str(cache_root()), revision=REVISIONS[SEGMENTATION], local_files_only=True)
        self.processor = AutoImageProcessor.from_pretrained(SEGMENTATION,use_fast=False,**args)
        # CPU background work leaves Metal inference scheduling to live navigation.
        self.model = AutoModelForSemanticSegmentation.from_pretrained(SEGMENTATION,use_safetensors=True,**args).eval()
        self.torch = torch
        names = {int(k):v.strip() for k,v in self.model.config.id2label.items()}
        self.wall = next(k for k,v in names.items() if v == "wall")
        self.floor = next(k for k,v in names.items() if v == "floor")
        self.dynamic = [k for k,v in names.items() if v in ("person","animal","car","bus","truck","bicycle","bag")]

    def infer(self, image):
        torch = self.torch
        with torch.inference_mode():
            inputs = self.processor(images=image,return_tensors="pt")
            logits = self.model(**inputs).logits
            probabilities = logits.softmax(dim=1)
            confidence, labels = probabilities.max(dim=1,keepdim=True)
            labels = torch.nn.functional.interpolate(labels.float(),size=(image.height,image.width),mode="nearest")[0,0].numpy().astype(np.int32)
            confidence = torch.nn.functional.interpolate(confidence,size=(image.height,image.width),mode="bilinear",align_corners=False)[0,0].numpy()
        return dict(wall=(labels == self.wall) & (confidence >= .65),
                    floor=(labels == self.floor) & (confidence >= .65),
                    dynamic=np.isin(labels,self.dynamic), confident=confidence >= .65)


def empty_floorplan():
    return dict(resolution=RESOLUTION, floor=[], occupied=[], walls=[], partial=True)


def _accumulate(existing, cells):
    counts = {(int(x),int(z)):int(n) for x,z,n in existing}
    for cell in set(map(tuple,cells)):
        if cell in counts:
            counts[cell] = min(65535,counts[cell]+1)
        elif len(counts) < MAX_CELLS and max(abs(cell[0]),abs(cell[1])) < 2048:
            counts[cell] = 1
    return [[int(x),int(z),int(n)] for (x,z),n in counts.items()]


def wall_candidates(points):
    """Vertical RANSAC planes backed by semantic wall pixels and vertical extent."""
    if len(points) < 80:
        return []
    remaining = points[::max(1,math.ceil(len(points)/2000))]
    rng = np.random.default_rng(741)
    result = []
    for _ in range(4):
        if len(remaining) < 80:
            break
        xz = remaining[:,[0,2]]
        best = None
        for _ in range(80):
            a,b = xz[rng.choice(len(xz),2,replace=False)]
            direction = b-a; length = np.linalg.norm(direction)
            if length < .5:
                continue
            normal = np.array([-direction[1],direction[0]])/length
            mask = np.abs(np.einsum('ij,j->i',xz-a,normal)) < .10
            if best is None or mask.sum() > best.sum():
                best = mask
        if best is None or best.sum() < 80:
            break
        inliers = remaining[best]
        remaining = remaining[~best]
        if np.ptp(inliers[:,1]) < .7:
            continue
        centre = np.mean(inliers[:,[0,2]],axis=0)
        _,_,vectors = np.linalg.svd(inliers[:,[0,2]]-centre,full_matrices=False)
        direction = vectors[0]
        along = np.einsum('ij,j->i',inliers[:,[0,2]]-centre,direction)
        low, high = np.quantile(along,[.03,.97])
        if high-low < .7:
            continue
        normal = np.array([-direction[1],direction[0]])
        error = float(np.median(np.abs(np.einsum('ij,j->i',inliers[:,[0,2]]-centre,normal))))
        result.append(dict(start=(centre+low*direction).tolist(),end=(centre+high*direction).tolist(),error=error))
    return result


def merge_walls(walls, candidates, pose):
    position, forward = pose[:3,3], pose[:3,2]
    for candidate in candidates:
        a,b = np.asarray(candidate["start"]),np.asarray(candidate["end"])
        direction = (b-a)/np.linalg.norm(b-a)
        match = None
        for wall in walls:
            c,d = np.asarray(wall["start"]),np.asarray(wall["end"])
            axis = (d-c)/np.linalg.norm(d-c)
            if abs(np.dot(direction,axis)) < math.cos(math.radians(8)):
                continue
            normal = np.array([-axis[1],axis[0]])
            if max(abs(np.dot(a-c,normal)),abs(np.dot(b-c,normal))) > .25:
                continue
            projected = np.array([np.dot(a-c,axis),np.dot(b-c,axis)])
            if projected.max() < -.5 or projected.min() > np.linalg.norm(d-c)+.5:
                continue
            match = wall; break
        if match is None:
            if len(walls) < 32:
                walls.append(dict(id=str(uuid.uuid4()),**candidate,observations=1,
                    lastPosition=position.tolist(),lastForward=forward.tolist()))
            continue
        old_position,old_forward = np.asarray(match["lastPosition"]),np.asarray(match["lastForward"])
        distinct = np.linalg.norm(position-old_position) > .05 or np.dot(forward,old_forward) < math.cos(math.radians(5))
        if not distinct:
            continue
        c,d = np.asarray(match["start"]),np.asarray(match["end"])
        axis = (d-c)/np.linalg.norm(d-c)
        extent = [0,np.linalg.norm(d-c),np.dot(a-c,axis),np.dot(b-c,axis)]
        match["start"] = (c+min(extent)*axis).tolist()
        match["end"] = (c+max(extent)*axis).tolist()
        match["observations"] = min(65535,match["observations"]+1)
        match["lastPosition"],match["lastForward"] = position.tolist(),forward.tolist()
        match["error"] = max(match["error"],candidate["error"])


def integrate_floorplan(plan, depth, geometry, camera, pose, semantic):
    if semantic is None:
        return
    h,w = depth.shape
    # 8px samples bound CPU and map growth independently from the live video rate.
    v,u = np.mgrid[4:h:8,4:w:8]
    z = depth[v,u] * geometry["scale"]
    rays = np.einsum('ij,kj->ik',np.column_stack([u.ravel(),v.ravel(),np.ones(u.size)]),np.linalg.inv(camera))
    camera_points = rays*z.ravel()[:,None]
    points = np.einsum('ij,kj->ik',camera_points,pose[:3,:3]) + pose[:3,3]
    valid = np.isfinite(points).all(axis=1) & (z.ravel() > .3) & (z.ravel() < 8)
    dynamic = semantic["dynamic"][v,u].ravel()
    floor = valid & semantic["floor"][v,u].ravel() & (np.abs(points[:,1]) < .3) & ~dynamic
    occupied = valid & semantic["confident"][v,u].ravel() & ~floor & ~dynamic & (points[:,1] > .15) & (points[:,1] < 2.2)
    cells = np.floor(points[valid][:,[0,2]]/plan["resolution"])
    if not np.isfinite(cells).all():
        return
    plan["floor"] = _accumulate(plan["floor"],np.floor(points[floor][:,[0,2]]/plan["resolution"]).astype(int))
    plan["occupied"] = _accumulate(plan["occupied"],np.floor(points[occupied][:,[0,2]]/plan["resolution"]).astype(int))
    wall = valid & semantic["wall"][v,u].ravel() & ~dynamic & (points[:,1] > .15) & (points[:,1] < 3.5)
    merge_walls(plan["walls"],wall_candidates(points[wall]),pose)
