import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import cv2
import numpy as np
from PIL import Image

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from mapping_store import LandmarkMap, MapStore
from room_mapper import RoomMapper, estimate_pose, initial_pose, intrinsics, rotation_difference
from floorplan import empty_floorplan, integrate_floorplan

GEOMETRY = dict(hfov=70,pitch=0,height=1.6,scale=1)
SOURCE = dict(kind="monocular_estimate",units="estimated_meters",model="SYNTHETIC TEST")


def correspondence_fixture():
    rng = np.random.default_rng(71)
    camera = intrinsics(640,480,70)
    pixels = rng.uniform([50,50],[590,430],(180,2))
    depth = rng.uniform(2,5,len(pixels))
    local = np.column_stack([pixels,np.ones(len(pixels))]) @ np.linalg.inv(camera).T * depth[:,None]
    origin = initial_pose(GEOMETRY)
    world = local @ origin[:3,:3].T+origin[:3,3]
    memory = LandmarkMap(camera=dict(imageSize=[640,480],mount=GEOMETRY),source=SOURCE,
        points=world,descriptors=rng.integers(0,256,(len(world),32),dtype=np.uint8),seen=np.full(len(world),3,np.uint16),keyframes=[origin.tolist()])
    return memory,camera,origin


def texture(seed=2):
    rng = np.random.default_rng(seed)
    image = cv2.GaussianBlur(rng.integers(0,256,(480,640),dtype=np.uint8),(3,3),0)
    return np.repeat(image[:,:,None],3,axis=2)


def view(image,x):
    focal = intrinsics(640,480,70)[0,0]
    shifted = cv2.warpAffine(image,np.array([[1,0,-focal*x/3],[0,1,0]],np.float32),(640,480),borderMode=cv2.BORDER_CONSTANT)
    return Image.fromarray(shifted)


def rendered_room(pose,width=320,height=240):
    camera = intrinsics(width,height,70)
    v,u = np.indices((height,width))
    rays = np.einsum('ij,kj->ik',np.column_stack([u.ravel(),v.ravel(),np.ones(u.size)]),np.linalg.inv(camera))
    rays = np.einsum('ij,kj->ik',rays,pose[:3,:3])
    origin = pose[:3,3]
    depths = np.full(u.size,np.inf); classes = np.full(u.size,-1)
    # A synthetic rectangular room. The rear wall remains unseen and must not be invented.
    for axis,value,label in [(0,-3,0),(0,3,0),(2,-5,0),(2,1,0),(1,0,1),(1,3,2)]:
        with np.errstate(divide="ignore",invalid="ignore"):
            t = (value-origin[axis])/rays[:,axis]
        with np.errstate(invalid="ignore"):
            points = origin + t[:,None]*rays
        inside = (points[:,0]>=-3.001)&(points[:,0]<=3.001)&(points[:,1]>=-.001)&(points[:,1]<=3.001)&(points[:,2]>=-5.001)&(points[:,2]<=1.001)
        use = (t>.01)&(t<depths)&inside
        depths[use]=t[use]; classes[use]=label
    labels=classes.reshape(height,width)
    semantic=dict(wall=labels==0,floor=labels==1,dynamic=np.zeros_like(labels,dtype=bool),confident=labels>=0)
    return depths.reshape(height,width).astype(np.float32),camera,semantic


class MappingTests(unittest.TestCase):
    def test_initial_tilt_seeds_gravity_aligned_map_without_changing_mount_metadata(self):
        tilt = cv2.Rodrigues(np.array([.4, 0., .5]))[0]
        with tempfile.TemporaryDirectory() as root:
            mapper = RoomMapper(root, SOURCE)
            image = Image.fromarray(texture())
            depth = np.full((480,640),3,np.float32)
            seeded = mapper.update(image, depth, GEOMETRY, 10, tilt=tilt)
            memory = mapper.maps[seeded["mapID"]]
            np.testing.assert_allclose(np.asarray(memory.keyframes[0])[:3,:3], tilt @ initial_pose(GEOMETRY)[:3,:3])
            self.assertEqual(memory.camera["mount"], GEOMETRY)
            # Dynamic attitude must not be compared as fixed camera calibration.
            mapper.update(image, depth, GEOMETRY, 10.2, tilt=tilt)
            tracked = mapper.update(image, depth, GEOMETRY, 10.4, tilt=tilt)
            self.assertEqual(tracked["status"], "tracking")
            self.assertEqual(tracked["mapID"], seeded["mapID"])

    def test_pose_recovers_translation_and_rotation_with_outliers(self):
        memory,camera,origin = correspondence_fixture()
        pose=origin.copy(); pose[0,3]=.2
        angle=np.deg2rad(8); turn=np.array([[np.cos(angle),0,np.sin(angle)],[0,1,0],[-np.sin(angle),0,np.cos(angle)]])
        pose[:3,:3]=turn@origin[:3,:3]
        rotation=pose[:3,:3].T; translation=-rotation@pose[:3,3]
        pixels=cv2.projectPoints(memory.points,cv2.Rodrigues(rotation)[0],translation,camera,None)[0].reshape(-1,2)
        depths=(memory.points@rotation.T+translation)[:,2]
        descriptors=memory.descriptors.copy()
        pixels[:25]=np.random.default_rng(3).uniform([50,50],[590,430],(25,2))
        result=estimate_pose(memory,pixels,descriptors,camera,depths)
        self.assertIsNotNone(result)
        np.testing.assert_allclose(result["pose"][:3,3],pose[:3,3],atol=.005)
        self.assertLess(rotation_difference(result["pose"],pose),.1)
        self.assertLess(result["count"],len(pixels))

    def test_weak_or_depth_inconsistent_matches_cannot_create_a_pose(self):
        memory,camera,pose=correspondence_fixture()
        rotation=pose[:3,:3].T; translation=-rotation@pose[:3,3]
        pixels=cv2.projectPoints(memory.points,cv2.Rodrigues(rotation)[0],translation,camera,None)[0].reshape(-1,2)
        depth=(memory.points@rotation.T+translation)[:,2]
        self.assertIsNone(estimate_pose(memory,pixels[:20],memory.descriptors[:20],camera,depth[:20]))
        self.assertIsNone(estimate_pose(memory,pixels,memory.descriptors,camera,depth*3))

    def test_orb_map_is_saved_and_relocalized_in_a_new_session(self):
        with tempfile.TemporaryDirectory() as root:
            mapper=RoomMapper(root,SOURCE); image=texture(); depth=np.full((480,640),3,np.float32)
            states=[]
            for i,x in enumerate([0,0,.12,.24,.36,.48]):
                states.append(mapper.update(view(image,x),depth,GEOMETRY,10+i*.2))
            mapper.flush()
            self.assertIn("tracking",[state["status"] for state in states])
            memory_id=states[-1]["mapID"]
            self.assertGreaterEqual(states[-1]["confirmed"],30)
            self.assertTrue((Path(root)/(memory_id+".json")).exists())
            restored=RoomMapper(root,SOURCE)
            first=restored.update(view(image,.24),depth,GEOMETRY,20)
            second=restored.update(view(image,.24),depth,GEOMETRY,20.2)
            self.assertEqual(first["status"],"confirming")
            self.assertEqual(second["status"],"relocalized")
            self.assertEqual(second["mapID"],memory_id)
            self.assertAlmostEqual(second["position"][0],.24,delta=.06)
            before=len(restored.maps[memory_id].keyframes)
            lost=restored.update(Image.fromarray(texture(88)),depth,GEOMETRY,21)
            self.assertIsNone(lost["position"])
            self.assertEqual(len(restored.maps[memory_id].keyframes),before)

    def test_changed_camera_calibration_does_not_reuse_a_saved_coordinate_frame(self):
        with tempfile.TemporaryDirectory() as root:
            mapper=RoomMapper(root,SOURCE); image=Image.fromarray(texture()); depth=np.full((480,640),3,np.float32)
            for i in range(3): mapper.update(image,depth,GEOMETRY,10+i*.2)
            mapper.flush()
            self.assertTrue(list(Path(root).glob("*.json")))
            restored=RoomMapper(root,SOURCE)
            for i in range(2):
                state=restored.update(image,depth,dict(GEOMETRY,hfov=80),20+i*.2)
                self.assertIsNone(state["position"])
                self.assertNotEqual(state["status"],"relocalized")

    def test_empty_room_memory_starts_without_a_scan_and_ignores_blank_frames(self):
        with tempfile.TemporaryDirectory() as root:
            mapper=RoomMapper(root,SOURCE)
            state=mapper.update(Image.new("RGB",(640,480),"white"),np.ones((480,640)),GEOMETRY,10)
            self.assertEqual(state["status"],"insufficient_features")
            self.assertIsNone(state["position"])
            self.assertEqual(list(Path(root).glob("*.json")),[])

    def test_floorplan_reconstructs_only_observed_walls_and_floor(self):
        plan=empty_floorplan()
        for x in [0,.12,.24]:
            pose=initial_pose(GEOMETRY); pose[0,3]=x
            depth,camera,semantic=rendered_room(pose)
            integrate_floorplan(plan,depth,GEOMETRY,camera,pose,semantic)
        self.assertTrue(plan["floor"]); self.assertTrue(plan["occupied"])
        self.assertTrue(any(w["observations"]>=3 for w in plan["walls"]))
        self.assertTrue(plan["partial"])
        for wall in plan["walls"]:
            for x,z in [wall["start"],wall["end"]]:
                self.assertLess(min(abs(x-3),abs(x+3),abs(z+5)),.2)
                self.assertLess(z,.5) # No invented rear boundary.
        count=max(w["observations"] for w in plan["walls"])
        integrate_floorplan(plan,depth,GEOMETRY,camera,pose,semantic)
        self.assertEqual(max(w["observations"] for w in plan["walls"]),count)

    def test_dynamic_or_unclassified_pixels_do_not_become_walls(self):
        plan=empty_floorplan(); pose=initial_pose(GEOMETRY)
        depth,camera,semantic=rendered_room(pose)
        semantic["dynamic"][:]=True
        integrate_floorplan(plan,depth,GEOMETRY,camera,pose,semantic)
        self.assertEqual(plan,empty_floorplan())
        integrate_floorplan(plan,depth,GEOMETRY,camera,pose,None)
        self.assertEqual(plan,empty_floorplan())


class StoreTests(unittest.TestCase):
    def test_round_trip_is_portable_and_contains_no_images(self):
        memory,_,_=correspondence_fixture()
        with tempfile.TemporaryDirectory() as root:
            depth,camera,semantic=rendered_room(initial_pose(GEOMETRY))
            integrate_floorplan(memory.floorplan,depth,GEOMETRY,camera,initial_pose(GEOMETRY),semantic)
            store=MapStore(root); store.save(memory)
            loaded,errors=store.load()
            self.assertEqual(errors,[]); self.assertEqual(loaded[0].id,memory.id)
            np.testing.assert_array_equal(loaded[0].descriptors,memory.descriptors)
            np.testing.assert_allclose(loaded[0].points,memory.points)
            self.assertNotIn("jpeg",json.dumps(memory.document()))
            self.assertEqual(loaded[0].source["units"],"estimated_meters")
            self.assertEqual(loaded[0].floorplan,memory.floorplan)
            self.assertTrue(loaded[0].floorplan["walls"])

    def test_corrupt_future_and_unregistered_maps_are_preserved_and_skipped(self):
        memory,_,_=correspondence_fixture()
        with tempfile.TemporaryDirectory() as root:
            store=MapStore(root); store.save(memory)
            path=Path(root)/"future.json"; path.write_text('{"schema":"future"}')
            maps,errors=store.load()
            self.assertEqual(len(maps),1); self.assertTrue(errors); self.assertTrue(path.exists())
            bad=memory.document(); bad["geometrySource"]={"kind":"lidar_scan","units":"meters"}
            with self.assertRaises(ValueError): LandmarkMap.from_document(bad)
            bad=memory.document(); bad["keyframes"]=[]
            with self.assertRaises(ValueError): LandmarkMap.from_document(bad)
            bad=memory.document(); bad["points"][0][0]=float("nan")
            with self.assertRaises(ValueError): LandmarkMap.from_document(bad)

    def test_atomic_failure_and_conflicting_session_cannot_overwrite_saved_memory(self):
        memory,_,_=correspondence_fixture()
        with tempfile.TemporaryDirectory() as root:
            store=MapStore(root); store.save(memory)
            other=store.load()[0][0]
            path=Path(root)/(memory.id+".json"); before=path.read_bytes()
            with patch("mapping_store.os.replace",side_effect=OSError("injected write failure")):
                with self.assertRaises(OSError): store.save(memory)
            self.assertEqual(path.read_bytes(),before)
            self.assertEqual(list(Path(root).glob("*.tmp")),[])
            store.save(memory)
            with self.assertRaises(ValueError): store.save(other)
            self.assertEqual(store.load()[0][0].revision,2)


class IsolationTests(unittest.TestCase):
    def test_mapping_mailbox_keeps_latest_frame_without_blocking_submission(self):
        from mapping_service import MappingService
        entered=threading.Event(); release=threading.Event()
        class Mapper:
            def __init__(self,*args): pass
            def update(self,*args,**kwargs): entered.set(); release.wait(2); return None
            def flush(self): pass
        class Segmentation:
            def infer(self,image): return None
        with tempfile.TemporaryDirectory() as root, patch("room_mapper.RoomMapper",Mapper),patch("floorplan.RoomSegmentation",Segmentation):
            service=MappingService(lambda value:None,SOURCE,root)
            request=dict(feed="front",geometry=GEOMETRY,captured=1)
            image=Image.new("RGB",(64,48)); depth=np.ones((48,64))
            service.submit(image,depth,request,[]); self.assertTrue(entered.wait(1))
            service.submit(image,depth,dict(request,captured=2),[])
            service.submit(image,depth,dict(request,captured=3),[])
            self.assertEqual(service.mailbox.qsize(),1)
            self.assertEqual(service.mailbox.get_nowait()[3],3)
            release.set(); service.close()

    def test_optional_mapping_startup_failure_does_not_stop_live_scenes(self):
        import base64,io
        import worker
        image=io.BytesIO(); Image.new("RGB",(64,48)).save(image,format="JPEG")
        request=dict(feed="front",id="test",target="",yaw=0,captured=10,geometry=GEOMETRY,jpeg=base64.b64encode(image.getvalue()).decode())
        class Backend:
            device="SYNTHETIC TEST"
            def infer(self,image,target): return np.full((image.height,image.width),3),[]
        events=[]
        with patch("mapping_service.MappingService",side_effect=OSError("injected map failure")),patch.object(worker.sys,"stdin",io.StringIO(json.dumps(request)+"\n")),patch.object(worker,"emit",events.append):
            worker.run(Backend(),mapping=True)
        self.assertIn("scene",[event["type"] for event in events])
        self.assertIn("map_error",[event["type"] for event in events])
        self.assertNotIn("error",[event["type"] for event in events])


if __name__ == "__main__": unittest.main()
