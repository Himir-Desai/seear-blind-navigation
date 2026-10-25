"""Bounded image-feature tracks, not repeated object classification.

Forward/backward LK, RANSAC and an appearance check fail closed on unsupported
motion/occlusion. Reclassification refreshes scores without snapping the box.
"""
from collections import deque
import uuid
import cv2
import numpy as np

CLASS_MAX_AGE = 2.5


def overlap(a, b):
    a,b = np.asarray(a),np.asarray(b)
    size = np.maximum(0,np.minimum(a[2:],b[2:])-np.maximum(a[:2],b[:2]))
    intersection = float(size.prod())
    return intersection / max(1e-9,float(np.prod(a[2:]-a[:2])+np.prod(b[2:]-b[:2]))-intersection)


class FlowTrack:
    def __init__(self, detection, gray, captured):
        self.id = str(uuid.uuid4())
        self.label,self.confidence = detection["label"],float(detection["confidence"])
        self.kind = detection.get("kind","item")
        self.classified = self.captured = captured
        self.gray = gray
        h,w = gray.shape
        box = np.clip(np.asarray(detection["box"],float),0,1)*[w,h,w,h]
        if box.shape != (4,) or not np.isfinite(box).all() or not 0 <= self.confidence <= 1 or not np.isfinite(captured):
            raise ValueError("Invalid tracking detection")
        x0,y0,x1,y1 = box
        if x1-x0 < 6 or y1-y0 < 6:
            raise ValueError("Insufficient tracking image support")
        self.polygon = np.array([[x0,y0],[x1,y0],[x1,y1],[x0,y1]],np.float32)
        self.points = self._features(gray)
        self.anchor = self._patch(gray)
        self.descriptors = None
        self.keypoints = None
        self.valid = self.points is not None and len(self.points) >= 6 and self.anchor.std() >= 3
        self.quality = 1.0 if self.valid else 0.0

    def _features(self, gray):
        mask = np.zeros(gray.shape,np.uint8)
        # Keep corner support inside the object, away from its background border.
        centre = self.polygon.mean(axis=0)
        inside = centre+(self.polygon-centre)*.85
        cv2.fillConvexPoly(mask,inside.astype(np.int32),255)
        return cv2.goodFeaturesToTrack(gray,maxCorners=64,qualityLevel=.005,minDistance=3,mask=mask,blockSize=3)

    def _patch(self, gray):
        destination = np.array([[0,0],[63,0],[63,63],[0,63]],np.float32)
        warp = cv2.getPerspectiveTransform(self.polygon,destination)
        return cv2.warpPerspective(gray,warp,(64,64)).astype(np.float32)

    @property
    def box(self):
        h,w = self.gray.shape
        return np.clip(np.r_[self.polygon.min(axis=0),self.polygon.max(axis=0)]/[w,h,w,h],0,1).tolist()

    def advance(self, gray, captured):
        if captured == self.captured:
            return self.valid
        if not self.valid or captured < self.captured or captured-self.captured > 1.0 or gray.shape != self.gray.shape:
            self.valid = False
            return False
        try:
            next_points,ok,_ = cv2.calcOpticalFlowPyrLK(self.gray,gray,self.points,None,winSize=(21,21),maxLevel=3)
            if next_points is None:
                self.valid = False; return False
            back,back_ok,_ = cv2.calcOpticalFlowPyrLK(gray,self.gray,next_points,None,winSize=(21,21),maxLevel=3)
            if back is None:
                self.valid = False; return False
            keep = ok.ravel().astype(bool)&back_ok.ravel().astype(bool)&(np.linalg.norm(back-self.points,axis=2).ravel()<1.5)
            before,after = self.points[keep],next_points[keep]
            if len(before) < 6:
                self.valid = False; return False
            matrix,inliers = cv2.estimateAffinePartial2D(before,after,method=cv2.RANSAC,ransacReprojThreshold=2,maxIters=300)
            if matrix is None or inliers.mean() < .6 or not .7 < np.linalg.norm(matrix[:,0]) < 1.4:
                self.valid = False; return False
            self.polygon = cv2.transform(self.polygon[None],matrix)[0].astype(np.float32)
            h,w = gray.shape
            viewport = np.array([[0,0],[w,0],[w,h],[0,h]],np.float32)
            visible,_ = cv2.intersectConvexConvex(self.polygon,viewport)
            fraction = visible/max(1.,cv2.contourArea(self.polygon))
            patch = self._patch(gray)
            a,b = self.anchor-self.anchor.mean(),patch-patch.mean()
            similarity = float(np.sum(a*b)/max(1e-6,np.linalg.norm(a)*np.linalg.norm(b)))
            if fraction < .6 or similarity < .55:
                self.valid = False; return False
            self.quality = min(1.,float(inliers.mean()),max(0.,similarity))
            self.points = after[inliers.ravel().astype(bool)]
            self.gray,self.captured = gray,captured
            if len(self.points) < 24:
                refreshed = self._features(gray)
                if refreshed is not None and len(refreshed)>=6:
                    self.points = refreshed
            return True
        except cv2.error:
            self.valid = False
            return False

    def same_appearance(self, other):
        a,b = self.anchor-self.anchor.mean(),other.anchor-other.anchor.mean()
        similarity = float(np.sum(a*b)/max(1e-6,np.linalg.norm(a)*np.linalg.norm(b)))
        if overlap(self.box,other.box)>=.4 and similarity>.92:
            return True
        for track in (self,other):
            if track.descriptors is None:
                track.keypoints,track.descriptors = cv2.ORB_create(nfeatures=96,edgeThreshold=5,patchSize=15,fastThreshold=8).detectAndCompute(track.anchor.astype(np.uint8),None)
        if self.descriptors is None or other.descriptors is None:
            return False
        pairs = cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(self.descriptors,other.descriptors,k=2)
        matches = [a for pair in pairs if len(pair)==2 for a,b in [pair] if a.distance<.72*b.distance]
        if len(matches)<8:
            return False
        before = np.float32([self.keypoints[m.queryIdx].pt for m in matches])
        after = np.float32([other.keypoints[m.trainIdx].pt for m in matches])
        matrix,inliers = cv2.estimateAffinePartial2D(before,after,method=cv2.RANSAC,ransacReprojThreshold=2,maxIters=300)
        return matrix is not None and inliers.mean()>=.7 and .6<np.linalg.norm(matrix[:,0])<1.6

    def detection(self, now):
        if not self.valid or not 0 <= now-self.classified <= CLASS_MAX_AGE:
            return None
        return dict(label=self.label,confidence=self.confidence,box=self.box,trackID=self.id,
                    classificationCaptured=self.classified,trackingQuality=self.quality)


class TrackBank:
    def __init__(self):
        cv2.setNumThreads(1)
        self.history = {feed:deque(maxlen=24) for feed in ("front","feet")}
        self.tracks = {feed:[] for feed in self.history}
        self.retired = {feed:[] for feed in self.history}
        self.token = None

    def query(self, token):
        if token != self.token:
            self.token = token
            for feed in self.tracks:
                self.tracks[feed] = [t for t in self.tracks[feed] if t.kind == "body"]
                self.retired[feed] = [t for t in self.retired[feed] if t.kind == "body"]

    def advance(self, feed, image, captured):
        gray = cv2.cvtColor(np.asarray(image),cv2.COLOR_RGB2GRAY)
        history = self.history[feed]
        if history and captured <= history[-1][0]:
            raise ValueError("Out-of-order tracking image")
        remaining = []
        for track in self.tracks[feed]:
            if track.advance(gray,captured) and captured-track.classified <= CLASS_MAX_AGE:
                remaining.append(track)
            else:
                self.retired[feed].append(track)
        self.tracks[feed] = remaining
        self.retired[feed] = [t for t in self.retired[feed][-24:] if captured-t.captured<=CLASS_MAX_AGE]
        history.append((captured,gray))

    def apply(self, result):
        feed,captured = result["feed"],result["captured"]
        history = self.history[feed]
        frames = [(stamp,gray) for stamp,gray in history if stamp >= captured]
        if not frames or frames[0][0] != captured or frames[-1][0]-captured > 1.5:
            return
        detections = [dict(d,kind="body") for d in result["body"]] + ([dict(d,kind="item") for d in result["objects"]] if result["token"]==self.token else [])
        used = set()
        for detection in sorted(detections,key=lambda d:d["confidence"],reverse=True):
            minimum = (.20 if detection["label"]=="shoe" else .25) if detection["kind"]=="body" else .15
            if detection["confidence"] < minimum:
                continue
            try:
                candidate = FlowTrack(detection,frames[0][1],captured)
            except (ValueError,cv2.error):
                continue
            for stamp,gray in frames[1:]:
                if not candidate.advance(gray,stamp):
                    break
            if not candidate.valid:
                continue
            matches = [(overlap(t.box,candidate.box),t) for t in self.tracks[feed]
                       if t.valid and t.kind==candidate.kind and t.label==candidate.label and t.id not in used]
            match = max(matches,key=lambda pair:pair[0],default=(0,None))
            if match[0] >= .3:
                current = match[1]
                if captured >= current.classified:
                    current.confidence,current.classified = candidate.confidence,captured
                used.add(current.id) # Keep its measured feature position and identity.
            else:
                # A short visual interruption may recover the same identity only
                # after a fresh classification and strong appearance evidence.
                recovered = [t for t in self.retired[feed] if t.kind==candidate.kind and t.label==candidate.label
                             and captured>t.classified and candidate.captured-t.captured<=CLASS_MAX_AGE
                             and candidate.same_appearance(t)]
                if len(recovered)==1:
                    candidate.id = recovered[0].id
                    self.retired[feed] = [t for t in self.retired[feed] if t.id!=candidate.id]
                self.tracks[feed].append(candidate); used.add(candidate.id)
        # Unmatched tracks retain their previous score only for CLASS_MAX_AGE.

    def prune(self, selected=None):
        for feed,tracks in self.tracks.items():
            groups = {}
            for track in sorted(tracks,key=lambda t:(t.id==selected,t.confidence),reverse=True):
                group = groups.setdefault((track.kind,track.label),[])
                if len(group)<8:
                    group.append(track)
            self.tracks[feed] = [t for group in groups.values() for t in group]

    def detections(self, feed, now, selected=None):
        body = [t.detection(now) for t in self.tracks[feed] if t.kind=="body"]
        objects = [t.detection(now) for t in self.tracks[feed] if t.kind=="item"]
        body = [d for d in body if d is not None]
        objects = [d for d in objects if d is not None]
        if selected:
            # Continue the lock and one best challenger; avoid following every false proposal.
            challenger = max((d for d in objects if d["trackID"]!=selected),key=lambda d:d["confidence"],default=None)
            keep = {selected,challenger["trackID"] if challenger else None}
            objects = [d for d in objects if d["trackID"] in keep]
        return objects,body
