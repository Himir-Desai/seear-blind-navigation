import base64
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import numpy as np
from PIL import Image

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from geometry import project,scene_geometry
from wearer import wearer_mask

GEOMETRY=dict(hfov=70,pitch=70,height=1.6,scale=1)


def fixture(forward_limits=(.15,.35), height=.18):
    h,w=240,320
    p=np.deg2rad(GEOMETRY["pitch"]); focal=w/(2*np.tan(np.deg2rad(35)))
    v=np.indices((h,w))[0]
    floor=GEOMETRY["height"]/(np.sin(p)+(v+.5-h/2)/focal*np.cos(p))
    x,fwd,_=project(floor,70,70,1.6)
    shoe=(abs(x)<.12)&(fwd>forward_limits[0])&(fwd<forward_limits[1])
    depth=floor.copy(); depth[shoe]*=(1.6-height)/1.6
    rgb=np.full((h,w,3),185,np.uint8); rgb[shoe]=[25,60,140]
    ys,xs=np.where(shoe)
    box=[xs.min()/w,ys.min()/h,(xs.max()+1)/w,(ys.max()+1)/h]
    detection=dict(label="shoe",confidence=.8,box=box)
    return Image.fromarray(rgb),depth,shoe,detection,floor


class WearerTests(unittest.TestCase):
    def test_worn_shoe_is_rejected_but_depth_coverage_and_item_remain(self):
        image,depth,shoe,detection,_=fixture()
        _,before,_=scene_geometry(depth,[],**GEOMETRY)
        self.assertTrue(before) # Reproduces the original false near obstacle.
        mask,info=wearer_mask(image,depth,[detection],"feet",GEOMETRY)
        self.assertGreater((mask&shoe).sum()/shoe.sum(),.95)
        self.assertFalse((mask&~shoe).any())
        objects,after,coverage=scene_geometry(depth,[dict(detection,label="backpack")],excluded=mask,**GEOMETRY)
        self.assertEqual(after,[]); self.assertEqual(coverage,1)
        self.assertEqual(objects[0]["label"],"backpack")
        self.assertLess(objects[0]["distance"],.4)
        self.assertEqual(info["shoes"],1); self.assertEqual(info["status"],"filtered")

    def test_close_low_obstacle_next_to_shoe_is_not_a_blind_zone(self):
        image,depth,shoe,detection,floor=fixture()
        x,fwd,_=project(floor,70,70,1.6)
        hazard=(x>.15)&(x<.35)&(fwd>.15)&(fwd<.4)
        depth[hazard]=floor[hazard]*(1.6-.20)/1.6
        mask,_=wearer_mask(image,depth,[detection],"feet",GEOMETRY)
        self.assertFalse(mask[hazard].any())
        _,obstacles,_=scene_geometry(depth,[],excluded=mask,**GEOMETRY)
        self.assertTrue(obstacles); self.assertLess(min(o["distance"] for o in obstacles),.5)

    def test_closer_object_inside_shoe_box_is_preserved(self):
        image,depth,shoe,detection,floor=fixture()
        v,u=np.indices(depth.shape)
        ys,xs=np.where(shoe)
        hazard=shoe&(u<xs.min()+(xs.max()-xs.min())*.35)
        depth[hazard]=floor[hazard]*(1.6-.65)/1.6
        mask,_=wearer_mask(image,depth,[detection],"feet",GEOMETRY)
        self.assertFalse(mask[hazard].any())
        _,obstacles,_=scene_geometry(depth,[],excluded=mask,**GEOMETRY)
        self.assertTrue(obstacles)

    def test_distant_shoe_and_front_camera_footwear_are_not_suppressed(self):
        image,depth,shoe,detection,_=fixture((.9,1.2))
        mask,info=wearer_mask(image,depth,[detection],"feet",GEOMETRY)
        self.assertFalse(mask.any()); self.assertEqual(info["shoes"],0)
        _,obstacles,_=scene_geometry(depth,[],excluded=mask,**GEOMETRY)
        self.assertTrue(obstacles)
        image,depth,shoe,detection,_=fixture()
        mask,info=wearer_mask(image,depth,[detection],"front",GEOMETRY)
        self.assertFalse(mask.any()); self.assertEqual(info["status"],"not_applicable")

    def test_leg_pixels_require_an_adjacent_accepted_shoe(self):
        image,depth,shoe,detection,floor=fixture()
        x,fwd,_=project(floor,70,70,1.6)
        leg=(abs(x)<.1)&(fwd>-.1)&(fwd<.15)
        depth[leg]=floor[leg]*(1.6-.55)/1.6
        rgb=np.array(image); rgb[leg]=[25,60,140]; image=Image.fromarray(rgb)
        ys,xs=np.where(leg); h,w=depth.shape
        leg_detection=dict(label="leg",confidence=.8,box=[xs.min()/w,ys.min()/h,(xs.max()+1)/w,(ys.max()+1)/h])
        only_leg,_=wearer_mask(image,depth,[leg_detection],"feet",GEOMETRY)
        self.assertFalse(only_leg.any())
        mask,info=wearer_mask(image,depth,[detection,leg_detection],"feet",GEOMETRY)
        self.assertEqual(info["legs"],1)
        self.assertGreater((mask&leg).sum()/leg.sum(),.95)

    def test_missing_weak_or_unlinked_leg_detection_keeps_occupancy(self):
        image,depth,shoe,detection,_=fixture()
        for detections in ([],[dict(detection,confidence=.1)],[dict(detection,label="leg")],
                           [dict(detection,box=[0,0,1,1])],[dict(detection,box=[float("nan"),0,1,1])]):
            mask,_=wearer_mask(image,depth,detections,"feet",GEOMETRY)
            self.assertFalse(mask.any())
            _,obstacles,_=scene_geometry(depth,[],excluded=mask,**GEOMETRY)
            self.assertTrue(obstacles)

    def test_segmentation_failure_never_erases_whole_detection_box(self):
        import cv2
        image,depth,shoe,detection,_=fixture()
        with patch("wearer.cv2.grabCut",side_effect=cv2.error("injected segmentation failure")):
            mask,_=wearer_mask(image,depth,[detection],"feet",GEOMETRY)
        self.assertFalse(mask.any())

    def test_footwear_filter_runs_in_neutral_worker_and_does_not_change_target(self):
        import worker
        image,depth,shoe,detection,_=fixture()
        data=io.BytesIO(); image.save(data,format="PNG")
        class Backend:
            device="SYNTHETIC TEST"
            def infer(self,*args): raise AssertionError("feet must run footwear detection even without a target")
            def infer_wearer(self,image,target):
                return depth,([dict(detection,label=target)] if target else []),[detection]
        request=dict(feed="feet",id="test",target="",yaw=0,captured=10,geometry=GEOMETRY,jpeg=base64.b64encode(data.getvalue()).decode())
        for target in ("","backpack"):
            events=[]
            with patch.object(worker.sys,"stdin",io.StringIO(json.dumps(dict(request,target=target))+"\n")),patch.object(worker,"emit",events.append):
                worker.run(Backend())
            self.assertNotIn("error",[e["type"] for e in events])
            scene=next(e["scene"] for e in events if e["type"]=="scene")
            self.assertEqual(scene["obstacles"],[])
            self.assertGreater(scene["wearerFilter"]["excludedPixels"],0)
            self.assertEqual([o["label"] for o in scene["objects"]],[target] if target else [])


if __name__=="__main__": unittest.main()
