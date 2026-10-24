import base64
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from geometry import project, scene_geometry


class GeometryTests(unittest.TestCase):
    def test_wall_is_obstacle_and_bearings_have_correct_sign(self):
        objects, hazards, coverage = scene_geometry(np.full((120, 160), 2.0), [
            dict(label="white cane", confidence=.8, box=[.1, .2, .3, .8]),
            dict(label="backpack", confidence=.9, box=[.7, .2, .9, .8])])
        self.assertEqual(coverage, 1)
        self.assertLess(objects[0]["bearing"], 0)
        self.assertGreater(objects[1]["bearing"], 0)
        self.assertTrue(hazards)

    def test_flat_floor_is_excluded_for_down_camera(self):
        # Includes a straight-down cap camera at the user's 5–6 ft mount heights.
        h, w = 120, 160
        focal = w / (2 * np.tan(np.deg2rad(35)))
        v = np.indices((h, w))[0]
        for height in (1.524,1.6,1.829):
            for pitch in (55,70,90):
                with self.subTest(height=height,pitch=pitch):
                    p=np.deg2rad(pitch)
                    depth=height/(np.sin(p)+(v+.5-h/2)/focal*np.cos(p))
                    _,hazards,_=scene_geometry(depth,[],pitch=pitch,height=height)
                    self.assertEqual(hazards,[])

    def test_straight_down_camera_keeps_horizontal_and_camera_ranges_distinct(self):
        depth=np.full((240,320),1.44,np.float32)
        objects,_,_=scene_geometry(depth,[dict(label="shoe",confidence=.9,box=[.47,.31,.53,.39])],pitch=90)
        self.assertEqual(len(objects),1)
        # The camera is 1.6 m high; a 16 cm-high shoe is ~1.45 m from the camera,
        # while its horizontal ground range can still be ~0.2 m.
        self.assertAlmostEqual(objects[0]["distance"],.227,delta=.015)
        self.assertLess(objects[0]["elevation"],-75)

    def test_invalid_depth_is_unavailable_not_empty_clear_scene(self):
        with np.errstate(invalid="ignore"):
            objects, hazards, coverage = scene_geometry(np.full((20, 20), np.nan), [])
        self.assertEqual(coverage, 0)
        self.assertEqual(objects, [])
        self.assertEqual(hazards, [])

    def test_camera_calibration_is_required_in_range(self):
        with self.assertRaises(ValueError):
            project(np.ones((20, 20)), hfov=0, pitch=0, height=1.6)
        with self.assertRaises(ValueError):
            scene_geometry(np.ones((20,20)), [], scale=0)

    def test_pipe_protocol_preserves_capture_time_and_errors(self):
        image = io.BytesIO(); Image.new("RGB", (160,120), "gray").save(image,format="JPEG")
        worker = Path(__file__).resolve().parents[1] / "worker.py"
        request = dict(id="fixture", feed="front", captured=123.5, yaw=30, target="white cane",
                       jpeg=base64.b64encode(image.getvalue()).decode(),
                       geometry=dict(hfov=70,pitch=0,height=1.6,scale=1))
        invalid = dict(request, jpeg="not base64")
        result = subprocess.run([sys.executable,str(worker),"--fixture"],
                                input=json.dumps(request)+"\n"+json.dumps(invalid)+"\n",text=True,
                                capture_output=True,timeout=20,check=True)
        rows = [json.loads(row) for row in result.stdout.splitlines()]
        self.assertEqual(rows[0]["device"], "SYNTHETIC TEST")
        self.assertEqual(rows[1]["scene"]["captured"],123.5)
        self.assertEqual(rows[1]["scene"]["objects"][0]["label"],"white cane")
        self.assertEqual(rows[2]["type"],"error")


if __name__ == "__main__":
    unittest.main()
