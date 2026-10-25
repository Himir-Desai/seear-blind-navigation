"""Analytic low blocks on a known floor, including cap tilt and wearer pixels."""
from pathlib import Path
import sys
import unittest
import cv2
import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from geometry import project,scene_geometry
from test_wearer import fixture,GEOMETRY
from wearer import wearer_mask


def floor_and_block(height=.04,forward=.16,lateral=0.,size=.05,tilt=None,mount=90,cap=1.6):
    shape=(240,320)
    _,_,unit_height=project(np.ones(shape),70,mount,cap,tilt)
    down=cap-unit_height
    with np.errstate(divide="ignore",invalid="ignore"):
        floor=np.where(down>.05,cap/down,np.nan)
    x,fwd,_=project(floor,70,mount,cap,tilt)
    block=(np.abs(x-lateral)<size/2)&(np.abs(fwd-forward)<size/2)
    depth=floor.copy(); depth[block]*=(cap-height)/cap
    return depth,block


class NearFeetTests(unittest.TestCase):
    def test_small_four_cm_block_below_tile_support_is_detected_only_by_feet_profile(self):
        depth,_=floor_and_block()
        _,front,_=scene_geometry(depth,[],pitch=90,feed="front")
        _,feet,coverage=scene_geometry(depth,[],pitch=90,feed="feet")
        self.assertEqual(front,[])
        self.assertTrue(feet); self.assertEqual(coverage,1)
        self.assertTrue(all(o["label"]=="low_obstacle" for o in feet))
        self.assertLess(min(o["distance"] for o in feet),.20)

    def test_block_inside_previous_ten_cm_cutoff_is_detected(self):
        depth,_=floor_and_block(forward=.07)
        _,feet,_=scene_geometry(depth,[],pitch=90,feed="feet")
        self.assertTrue(feet)
        self.assertLess(feet[0]["distance"],.1)

    def test_flat_floor_below_threshold_side_and_far_blocks_are_not_low_alerts(self):
        for arguments in [dict(height=0),dict(height=.02),dict(forward=.7),dict(lateral=.45),dict(forward=-.15)]:
            with self.subTest(**arguments):
                depth,_=floor_and_block(**arguments)
                _,feet,_=scene_geometry(depth,[],pitch=90,feed="feet")
                self.assertEqual(feet,[])

    def test_isolated_depth_spikes_do_not_form_supported_low_obstacles(self):
        depth,_=floor_and_block(height=0)
        depth[110,158]=1.54; depth[114,161]=1.54
        _,feet,_=scene_geometry(depth,[],pitch=90,feed="feet")
        self.assertEqual(feet,[])

    def test_tilted_caps_keep_floor_excluded_and_low_blocks_in_ground_coordinates(self):
        for cap in (1.524,1.829):
            for pitch,roll in [(-10,15),(12,-18)]:
                with self.subTest(cap=cap,pitch=pitch,roll=roll):
                    tilt=cv2.Rodrigues(np.array([np.deg2rad(pitch),0.,0.]))[0] @ cv2.Rodrigues(np.array([0.,0.,np.deg2rad(roll)]))[0]
                    depth,_=floor_and_block(tilt=tilt,cap=cap)
                    _,feet,_=scene_geometry(depth,[],pitch=90,height=cap,tilt=tilt,feed="feet")
                    self.assertTrue(feet)
                    self.assertAlmostEqual(feet[0]["distance"],.14,delta=.035)
                    floor,_=floor_and_block(height=0,tilt=tilt,cap=cap)
                    self.assertEqual(scene_geometry(floor,[],pitch=90,height=cap,tilt=tilt,feed="feet")[1],[])

    def test_worn_shoe_is_filtered_but_nearby_low_block_is_retained(self):
        image,depth,shoe,detection,floor=fixture()
        x,fwd,_=project(floor,70,70,1.6)
        low=(x>.15)&(x<.23)&(fwd>.18)&(fwd<.26)
        depth[low]=floor[low]*(1.6-.04)/1.6
        mask,_=wearer_mask(image,depth,[detection],"feet",GEOMETRY)
        self.assertFalse(mask[low].any())
        _,obstacles,_=scene_geometry(depth,[],excluded=mask,feed="feet",**GEOMETRY)
        self.assertTrue(obstacles)
        self.assertTrue(all(o["label"]=="low_obstacle" for o in obstacles))
        self.assertTrue(all(o["bearing"]>20 for o in obstacles))

    def test_exclusion_mask_cannot_change_depth_coverage_or_item_observation(self):
        depth,block=floor_and_block()
        detection=dict(label="backpack",confidence=.8,box=[.4,.35,.6,.6])
        before=scene_geometry(depth,[detection],pitch=90,feed="feet")
        after=scene_geometry(depth,[detection],pitch=90,feed="feet",excluded=block)
        self.assertEqual(after[1],[]); self.assertEqual(before[0],after[0]); self.assertEqual(before[2],after[2])

    def test_both_worker_paths_receive_explicit_feet_profile(self):
        import worker
        import base64,io,json
        from PIL import Image
        from unittest.mock import patch
        depth,_=floor_and_block()
        image=Image.new("RGB",(320,240)); data=io.BytesIO(); image.save(data,format="PNG")
        class Legacy:
            device="SYNTHETIC TEST"
            def infer(self,image,target): return depth,[]
        class Live(Legacy):
            def estimate_depth(self,image): return depth
            def detect(self,*args,**kwargs): return [],[]
        request=dict(feed="feet",id="test",target="",yaw=0,captured=10,geometry=dict(hfov=70,pitch=90,height=1.6,scale=1),jpeg=base64.b64encode(data.getvalue()).decode())
        for Backend in (Legacy,Live):
            with self.subTest(backend=Backend.__name__):
                events=[]
                with patch.object(worker.sys,"stdin",io.StringIO(json.dumps(request)+"\n")),patch.object(worker,"emit",events.append):
                    worker.run(Backend())
                scene=next(event["scene"] for event in events if event["type"]=="scene")
                self.assertTrue(scene["obstacles"])
                self.assertEqual(scene["obstacles"][0]["label"],"low_obstacle")


if __name__=="__main__": unittest.main()
