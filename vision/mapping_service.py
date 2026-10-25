"""Best-effort background mapping. A one-frame mailbox never queues up camera history."""
import queue
import threading
from pathlib import Path
import time
import os


class MappingService:
    def __init__(self, emit, source, root=None):
        self.emit = emit
        self.source = source
        self.root = root or os.environ.get("SEEAR_MAPS", str(Path(__file__).resolve().parents[1] / "data/maps"))
        self.mailbox = queue.Queue(maxsize=1)
        self.stopping = threading.Event()
        self.disabled = False
        self.last_submit = -float("inf")
        self.thread = threading.Thread(target=self._run, name="room-memory", daemon=True)
        self.thread.start()

    def submit(self, image, depth, request, objects):
        if self.disabled or self.stopping.is_set() or request["feed"] != "front":
            return
        if request["captured"]-self.last_submit < .5:
            return # At most 2 Hz; faster live depth must not flood CPU segmentation.
        self.last_submit = request["captured"]
        task = (image.copy(), depth.copy(), dict(request["geometry"]), request["captured"],
                [o["box"] for o in objects if o["box"]], request.get("tilt"))
        try:
            self.mailbox.put_nowait(task)
        except queue.Full:
            try:
                self.mailbox.get_nowait()
            except queue.Empty:
                pass
            try:
                self.mailbox.put_nowait(task)
            except queue.Full:
                pass

    def _run(self):
        mapper = None
        try:
            from room_mapper import RoomMapper
            from floorplan import RoomSegmentation
            mapper = RoomMapper(self.root,self.source)
            segmentation = RoomSegmentation()
            while not self.stopping.is_set():
                try:
                    task = self.mailbox.get(timeout=.1)
                except queue.Empty:
                    continue
                semantic = segmentation.infer(task[0])
                result = mapper.update(*task[:5],semantic=semantic,tilt=task[5])
                if result is not None:
                    self.emit(dict(type="map",map=result))
        except Exception as exc:
            self.disabled = True
            self.emit(dict(type="map_error",message="Room memory unavailable: " + str(exc)))
        finally:
            if mapper is not None:
                try:
                    mapper.flush()
                except Exception as exc:
                    self.emit(dict(type="map_error",message="Final map checkpoint unavailable: " + str(exc)))

    def close(self):
        self.stopping.set()
        self.thread.join(timeout=2)
