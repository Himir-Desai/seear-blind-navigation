"""Conservative ego-footwear candidates; never create a distance-only blind zone."""
import cv2
import numpy as np
from geometry import project


def _box(value, width, height):
    box = np.asarray(value,dtype=float)
    if box.shape != (4,) or not np.isfinite(box).all():
        return None
    a,b,c,d = np.clip(box,0,1)
    if c <= a or d <= b:
        return None
    x0,y0,x1,y1 = int(a*width),int(b*height),min(width,int(np.ceil(c*width))),min(height,int(np.ceil(d*height)))
    if x1-x0 < 4 or y1-y0 < 4:
        return None
    return x0,y0,x1,y1


def _foreground(rgb, depth, box, eligible):
    """RGB foreground within a detection, constrained by depth/near-body support.

    Hard background includes floor, higher objects and different-depth surfaces.
    No fallback to erasing the entire detection rectangle on segmentation failure.
    """
    h,w = depth.shape
    x0,y0,x1,y1 = box
    cx,cy = (x0+x1)/2,(y0+y1)/2
    v,u = np.indices((y1-y0,x1-x0))
    centre = (abs(u+x0-cx) < (x1-x0)*.25) & (abs(v+y0-cy) < (y1-y0)*.25)
    seed = centre & eligible[y0:y1,x0:x1]
    if seed.sum() < 8:
        return np.zeros((h,w),bool)
    reference = float(np.median(depth[y0:y1,x0:x1][seed]))
    supported = eligible & (np.abs(depth-reference) < max(.08,.06*reference))
    padding = max(3,int(max(x1-x0,y1-y0)*.12))
    a,b,c,d = max(0,x0-padding),max(0,y0-padding),min(w,x1+padding),min(h,y1+padding)
    mask = np.full((d-b,c-a),cv2.GC_BGD,np.uint8)
    inside = mask[y0-b:y1-b,x0-a:x1-a]
    inside[supported[y0:y1,x0:x1]] = cv2.GC_PR_FGD
    inside[seed & supported[y0:y1,x0:x1]] = cv2.GC_FGD
    if not np.any(mask == cv2.GC_BGD):
        return np.zeros((h,w),bool)
    cv2.grabCut(np.ascontiguousarray(rgb[b:d,a:c]),mask,None,np.zeros((1,65)),np.zeros((1,65)),2,cv2.GC_INIT_WITH_MASK)
    result = np.zeros((h,w),bool)
    result[b:d,a:c] = (mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD)
    return result & supported


def wearer_mask(image, depth, detections, feed, geometry):
    """Suppress only RGB footwear/linked-leg pixels in a small estimated body volume.

    Category + geometry is a heuristic, not proof of ownership. Uncertain pixels
    stay in occupancy; loose/other people's footwear inside this volume can alias.
    """
    depth = np.asarray(depth,dtype=np.float32)*geometry["scale"]
    empty = np.zeros(depth.shape,bool)
    info = dict(status="not_applicable",excludedPixels=0,shoes=0,legs=0)
    if feed != "feet" or geometry["pitch"] < 35:
        return empty,info
    info["status"] = "no_match"
    rgb = np.asarray(image)
    if rgb.shape != (*depth.shape,3):
        raise ValueError("Wearer filter image/depth mismatch")
    h,w = depth.shape
    x,forward,vertical = project(depth,geometry["hfov"],geometry["pitch"],geometry["height"])
    valid = np.isfinite(depth) & (depth > .05) & (depth < 30)
    shoe_volume = valid & (np.abs(x) < .38) & (forward > -.25) & (forward < .65) & (vertical > .025) & (vertical < .4)
    leg_volume = valid & (np.abs(x) < .35) & (forward > -.3) & (forward < .5) & (vertical > .025) & (vertical < min(.9,.6*geometry["height"]))
    result,shoes = empty.copy(),[]
    for detection in detections:
        if detection.get("label") != "shoe" or not .20 <= detection.get("confidence",0) <= 1:
            continue
        box = _box(detection.get("box"),w,h)
        if box is None:
            continue
        x0,y0,x1,y1 = box
        if (x1-x0)*(y1-y0) > .15*w*h or shoe_volume[y0:y1,x0:x1].mean() < .5:
            continue
        try:
            mask = _foreground(rgb,depth,box,shoe_volume)
        except cv2.error:
            continue
        if mask.sum() >= 8:
            result |= mask; shoes.append(box)
    info["shoes"] = len(shoes)
    for detection in detections:
        if detection.get("label") != "leg" or not .25 <= detection.get("confidence",0) <= 1 or not shoes:
            continue
        box = _box(detection.get("box"),w,h)
        if box is None:
            continue
        x0,y0,x1,y1 = box
        # Legs require an adjacent accepted shoe, rather than erasing arbitrary
        # person/leg detections or furniture legs near the wearer.
        linked = any(max(a-x1,x0-c,0) <= .04*w and max(b-y1,y0-d,0) <= .04*h for a,b,c,d in shoes)
        if not linked or (x1-x0)*(y1-y0) > .25*w*h:
            continue
        try:
            mask = _foreground(rgb,depth,box,leg_volume)
        except cv2.error:
            continue
        if mask.sum() >= 8:
            result |= mask; info["legs"] += 1
    if result.mean() > .3:
        info.update(status="mask_rejected",shoes=0,legs=0)
        return empty,info
    info.update(status="filtered" if result.any() else "no_match",excludedPixels=int(result.sum()))
    return result,info
