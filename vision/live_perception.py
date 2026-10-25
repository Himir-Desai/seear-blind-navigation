"""Fresh depth/optical-flow path with a bounded, slower background classifier."""
import threading
import time
from tracking import TrackBank


class DetectionService:
    def __init__(self, backend, interval=1.0, clock=time.monotonic):
        self.backend,self.interval,self.clock = backend,interval,clock
        self.condition = threading.Condition()
        self.pending,self.results,self.started = {},{},{}
        self.stopping = False
        self.busy = False
        self.error = ""
        self.thread = threading.Thread(target=self._run,name="item-classifier",daemon=True)
        self.thread.start()

    def offer(self, image, request):
        if not request["target"] and request["feed"] != "feet":
            return
        job = dict(feed=request["feed"],captured=request["captured"],target=request["target"],
                   token=request.get("searchID",request["target"]),image=image,offered=self.clock())
        with self.condition:
            self.pending[job["feed"]] = job # At most the latest image for each feed.
            self.condition.notify()

    def take(self):
        with self.condition:
            results = list(self.results.values()); self.results.clear()
            return results

    def _run(self):
        while True:
            with self.condition:
                if self.stopping:
                    return
                now = self.clock()
                self.pending = {f:j for f,j in self.pending.items() if now-j["offered"]<.4}
                eligible = [j for f,j in self.pending.items() if now-self.started.get((f,j["token"]),-1e9)>=self.interval]
                if not eligible:
                    self.condition.wait(timeout=.05)
                    continue
                job = min(eligible,key=lambda j:self.started.get((j["feed"],j["token"]),-1e9))
                del self.pending[job["feed"]]
                self.started[(job["feed"],job["token"])] = now
                # Do not grow the schedule history with repeated spoken Find commands.
                if len(self.started)>8:
                    self.started = {k:v for k,v in self.started.items() if now-v<5}
                self.busy = True
            try:
                start = self.clock()
                objects,body = self.backend.detect(job["image"],job["target"],wearer=job["feed"]=="feet")
                result = dict(feed=job["feed"],captured=job["captured"],token=job["token"],objects=objects,body=body,
                              detectorMS=(self.clock()-start)*1000)
                with self.condition:
                    self.results[job["feed"]] = result
                    self.error = ""
            except Exception as exc:
                # Classifier failure cannot stop fresh depth/obstacle processing.
                with self.condition:
                    self.error = str(exc)[:160]
            finally:
                with self.condition:
                    self.busy = False

    def close(self):
        with self.condition:
            self.stopping = True; self.pending.clear(); self.condition.notify()
        self.thread.join(timeout=2)


class LivePerception:
    def __init__(self, backend, detector=None):
        self.backend = backend
        self.detector = detector or DetectionService(backend)
        self.bank = TrackBank()
        self.selected = None
        self.last_classified = {}
        self.detector_ms = {}

    def process(self, image, request):
        from geometry import scene_geometry
        from wearer import wearer_mask
        feed,stamp = request["feed"],request["captured"]
        token = request.get("searchID",request["target"])
        if token != self.bank.token:
            self.selected = None
            self.last_classified.clear(); self.detector_ms.clear()
        self.bank.query(token)
        if request.get("selectedTrackID"):
            self.selected = request["selectedTrackID"]
        self.detector.offer(image,request)
        start = time.monotonic()
        depth = self.backend.estimate_depth(image) # No object detector in this path.
        depth_ms = (time.monotonic()-start)*1000
        start = time.monotonic()
        self.bank.advance(feed,image,stamp)
        for result in self.detector.take():
            self.bank.apply(result)
            if result["token"]==token:
                self.last_classified[result["feed"]] = result["captured"]
                self.detector_ms[result["feed"]] = result["detectorMS"]
        self.bank.prune(self.selected)
        detections,body = self.bank.detections(feed,stamp,self.selected)
        tracking_ms = (time.monotonic()-start)*1000
        geometry,tilt = request["geometry"],request.get("tilt")
        excluded,filter_info = wearer_mask(image,depth,body,feed,geometry,tilt)
        objects,obstacles,coverage = scene_geometry(depth,detections,excluded=excluded,tilt=tilt,feed=feed,**geometry)
        classified = self.last_classified.get(feed)
        mode = "tracking" if objects else "searching" if request["target"] else "monitoring"
        stats = dict(depthMS=depth_ms,trackingMS=tracking_ms,detectorMS=self.detector_ms.get(feed,0),mode=mode,
                     classified=classified,detectorBusy=self.detector.busy,classifierError=self.detector.error)
        return depth,objects,obstacles,coverage,filter_info,stats

    def close(self):
        self.detector.close()
