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

    def test_tilted_floor_stays_floor_for_both_mounts(self):
        import cv2
        for mount in (0, 90):
            for pitch, roll in [(-70, 0), (-20, 35), (30, -60), (89, 90), (100, 140), (179, 179)]:
                with self.subTest(mount=mount, pitch=pitch, roll=roll):
                    rx = cv2.Rodrigues(np.array([np.deg2rad(pitch), 0., 0.]))[0]
                    rz = cv2.Rodrigues(np.array([0., 0., np.deg2rad(roll)]))[0]
                    tilt = rx @ rz
                    unit = np.ones((120, 160))
                    _, _, height = project(unit, 70, mount, 1.6, tilt)
                    down = 1.6-height
                    with np.errstate(divide="ignore", invalid="ignore"):
                        depth = np.where(down > .06, 1.6/down, np.nan)
                    _, _, vertical = project(depth, 70, mount, 1.6, tilt)
                    finite = np.isfinite(depth) & (depth < 30)
                    if finite.any():
                        np.testing.assert_allclose(vertical[finite], 0, atol=1e-10)
                    _, hazards, _ = scene_geometry(depth, [], pitch=mount, tilt=tilt)
                    self.assertEqual(hazards, [])

    def test_roll_preserves_a_real_near_obstacle_and_world_direction(self):
        import cv2
        tilt = cv2.Rodrigues(np.array([0., 0., np.deg2rad(55)]))[0]
        depth = np.full((120, 160), 2.)
        objects, hazards, coverage = scene_geometry(depth, [dict(label="backpack", confidence=.8, box=[.6,.3,.8,.6])], tilt=tilt)
        self.assertEqual(coverage, 1)
        self.assertTrue(hazards)
        x, forward, vertical = project(depth, 70, 0, 1.6, tilt)
        # The projected central box median has the same world location whether
        # obtained from the full optical/map transform or the live projection.
        from room_mapper import initial_pose, intrinsics
        mount = dict(hfov=70, pitch=0, height=1.6, scale=1)
        pose = initial_pose(mount, tilt)
        pixel = np.array([112., 54., 1.])
        point = pose[:3,:3] @ (np.linalg.inv(intrinsics(160,120,70)) @ pixel*2) + pose[:3,3]
        np.testing.assert_allclose([x[54,112], vertical[54,112], -forward[54,112]], point, atol=1e-8)
        self.assertGreater(objects[0]["bearing"], 0)

    def test_invalid_dynamic_rotations_are_errors(self):
        for tilt in ([1,2], np.zeros((3,3)), np.diag([1,1,-1]), np.full((3,3), np.nan)):
            with self.subTest(tilt=str(tilt)), self.assertRaises(ValueError):
                scene_geometry(np.ones((20,20)), [], tilt=tilt)

    def test_pipe_protocol_preserves_capture_time_and_errors(self):
        image = io.BytesIO(); Image.new("RGB", (160,120), "gray").save(image,format="JPEG")
        worker = Path(__file__).resolve().parents[1] / "worker.py"
        request = dict(id="fixture", feed="front", captured=123.5, yaw=30, target="white cane",
                       jpeg=base64.b64encode(image.getvalue()).decode(),
                       geometry=dict(hfov=70,pitch=0,height=1.6,scale=1))
        request["tilt"] = [1,0,0,0,.5,-3**.5/2,0,3**.5/2,.5]
        request["rotation"] = dict(x=.5,y=0,z=0,w=3**.5/2)
        invalid = dict(request, tilt=[0]*9)
        result = subprocess.run([sys.executable,str(worker),"--fixture"],
                                input=json.dumps(request)+"\n"+json.dumps(invalid)+"\n",text=True,
                                capture_output=True,timeout=20,check=True)
        rows = [json.loads(row) for row in result.stdout.splitlines()]
        self.assertEqual(rows[0]["device"], "SYNTHETIC TEST")
        self.assertEqual(rows[1]["scene"]["captured"],123.5)
        self.assertEqual(rows[1]["scene"]["rotation"],request["rotation"])
        self.assertEqual(rows[1]["scene"]["obstacles"],[])
        self.assertEqual(rows[1]["scene"]["objects"][0]["label"],"white cane")
        self.assertEqual(rows[2]["type"],"error")


if __name__ == "__main__":
    unittest.main()
