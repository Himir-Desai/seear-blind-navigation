import sys
import threading
from pathlib import Path
import unittest
import cv2
import numpy as np
from PIL import Image

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from tracking import FlowTrack,TrackBank,CLASS_MAX_AGE
from live_perception import DetectionService,LivePerception


def scene(dx=0, dy=0, angle=0, occluded=False, seed=18):
    rng = np.random.default_rng(seed)
    gray = np.full((240,320),35,np.uint8)
    texture = cv2.GaussianBlur(rng.integers(30,240,(100,80),dtype=np.uint8),(3,3),0)
    gray[70:170,80:160] = texture
    gray[40:120,220:290] = rng.integers(30,240,(80,70),dtype=np.uint8)
    matrix = cv2.getRotationMatrix2D((120,120),angle,1)
    matrix[:,2] += [dx,dy]
    gray = cv2.warpAffine(gray,matrix,(320,240),borderValue=35)
    if occluded:
        gray[:,:200] = 35
    return Image.fromarray(np.repeat(gray[:,:,None],3,axis=2))


BOX = [80/320,70/240,160/320,170/240]
DETECTION = dict(label="backpack",confidence=.8,box=BOX)
GEOMETRY = dict(hfov=70,pitch=0,height=1.6,scale=1)


def result(stamp=10, objects=None, token="find", body=None):
    return dict(feed="front",captured=stamp,token=token,objects=objects if objects is not None else [DETECTION],body=body or [],detectorMS=300)


class TrackingTests(unittest.TestCase):
    def bank(self):
        bank = TrackBank(); bank.query("find")
        bank.advance("front",scene(),10); bank.apply(result())
        return bank

    def test_visual_identity_follows_translation_and_rotation_without_classifier(self):
        bank = self.bank()
        identity = bank.detections("front",10)[0][0]["trackID"]
        for i in range(1,6):
            bank.advance("front",scene(dx=i*4,dy=-i*2,angle=i*2),10+i*.1)
            objects,_ = bank.detections("front",10+i*.1)
            self.assertEqual(len(objects),1)
            self.assertEqual(objects[0]["trackID"],identity)
            self.assertEqual(objects[0]["classificationCaptured"],10)
            center = (np.array(objects[0]["box"][:2])+objects[0]["box"][2:])/2
            np.testing.assert_allclose(center,[float(120+i*4)/320,float(120-i*2)/240],atol=.012)

    def test_late_classifier_box_is_advanced_to_current_image_before_publication(self):
        bank = TrackBank(); bank.query("find")
        for i in range(5): bank.advance("front",scene(dx=i*5),10+i*.1)
        bank.apply(result())
        objects,_ = bank.detections("front",10.4)
        self.assertEqual(len(objects),1)
        center = (objects[0]["box"][0]+objects[0]["box"][2])/2
        self.assertAlmostEqual(center,140/320,delta=.01)

    def test_reclassification_updates_confidence_without_snapping_or_changing_id(self):
        bank = self.bank(); first = bank.detections("front",10)[0][0]
        bank.advance("front",scene(dx=8),10.1)
        before = bank.detections("front",10.1)[0][0]
        shifted = dict(DETECTION,confidence=.55,box=(np.array(BOX)+[.015,-.01,.015,-.01]).tolist())
        bank.apply(result(10.1,objects=[shifted]))
        after = bank.detections("front",10.1)[0][0]
        self.assertEqual(after["trackID"],first["trackID"])
        self.assertEqual(after["confidence"],.55)
        self.assertEqual(after["classificationCaptured"],10.1)
        self.assertEqual(after["box"],before["box"])

    def test_occlusion_does_not_jump_to_distractor_or_replay_old_item(self):
        bank = self.bank()
        bank.advance("front",scene(occluded=True),10.1)
        self.assertEqual(bank.detections("front",10.1)[0],[])
        bank.advance("front",scene(dx=5),10.2)
        self.assertEqual(bank.detections("front",10.2)[0],[])

    def test_expired_classification_gap_and_stale_results_cannot_renew_a_track(self):
        bank = self.bank()
        self.assertEqual(bank.detections("front",10+CLASS_MAX_AGE+.01)[0],[])
        bank.advance("front",scene(),11.1)
        self.assertEqual(bank.detections("front",11.1)[0],[])
        bank.apply(result(stamp=9))
        self.assertEqual(bank.detections("front",11.1)[0],[])

    def test_fresh_classification_can_recover_same_identity_after_short_occlusion(self):
        bank = self.bank(); identity=bank.detections("front",10)[0][0]["trackID"]
        bank.advance("front",scene(occluded=True),10.1)
        bank.advance("front",scene(),10.2)
        self.assertEqual(bank.detections("front",10.2)[0],[])
        bank.apply(result(stamp=10.2))
        current=bank.detections("front",10.2)[0][0]
        self.assertEqual(current["trackID"],identity)
        self.assertEqual(current["classificationCaptured"],10.2)

    def test_same_label_and_position_cannot_recover_a_different_appearance(self):
        bank = self.bank(); identity=bank.detections("front",10)[0][0]["trackID"]
        bank.advance("front",scene(occluded=True),10.1)
        bank.advance("front",scene(seed=35),10.2)
        bank.apply(result(stamp=10.2))
        current=bank.detections("front",10.2)[0][0]
        self.assertNotEqual(current["trackID"],identity)

    def test_same_query_with_new_search_token_cannot_acquire_old_result(self):
        bank = self.bank(); bank.query("find-again")
        bank.apply(result())
        self.assertEqual(bank.detections("front",10)[0],[])

    def test_item_shoe_does_not_become_body_footwear(self):
        bank = TrackBank(); bank.query("find")
        bank.advance("front",scene(),10)
        bank.apply(result(objects=[dict(DETECTION,label="shoe")]))
        objects,body = bank.detections("front",10)
        self.assertEqual(len(objects),1); self.assertEqual(body,[])

    def test_box_touching_image_edge_keeps_its_supported_visible_track(self):
        bank = TrackBank(); bank.query("find")
        image = scene(dx=160)
        bank.advance("front",image,10)
        detection = dict(DETECTION,box=(np.array(BOX)+[.5,0,.5,0]).tolist())
        bank.apply(result(objects=[detection]))
        identity = bank.detections("front",10)[0][0]["trackID"]
        bank.advance("front",image,10.1)
        self.assertEqual(bank.detections("front",10.1)[0][0]["trackID"],identity)

    def test_duplicate_image_is_rejected_instead_of_making_a_fresh_track(self):
        bank = self.bank()
        with self.assertRaises(ValueError): bank.advance("front",scene(),10)


class FakeDetector:
    busy = False
    error = ""
    def __init__(self): self.results=[]; self.jobs=[]
    def offer(self,image,request): self.jobs.append(request)
    def take(self): results,self.results=self.results,[]; return results
    def close(self): pass


class DepthOnly:
    def estimate_depth(self,image): return np.full((image.height,image.width),2,np.float32)


class PipelineTests(unittest.TestCase):
    def request(self,stamp=10):
        return dict(feed="front",captured=stamp,target="backpack",searchID="find",geometry=GEOMETRY)

    def test_delayed_classification_never_blocks_fresh_depth(self):
        entered,release,finished=threading.Event(),threading.Event(),threading.Event()
        class Backend(DepthOnly):
            def detect(self,*args,**kwargs):
                entered.set(); release.wait(2); finished.set(); return [DETECTION],[]
        pipeline=LivePerception(Backend())
        try:
            first=pipeline.process(scene(),self.request())
            self.assertTrue(entered.wait(1))
            for i in range(1,5):
                current=pipeline.process(scene(dx=i),self.request(10+i*.1))
                self.assertEqual(current[3],1)
                self.assertTrue(current[2]) # Class-independent occupancy stays live.
            self.assertFalse(finished.is_set())
            self.assertLessEqual(len(pipeline.detector.pending),2)
        finally:
            release.set(); pipeline.close()

    def test_background_result_seeds_visual_tracking_with_real_classification_age(self):
        detector=FakeDetector(); pipeline=LivePerception(DepthOnly(),detector)
        pipeline.process(scene(),self.request())
        detector.results=[result()]
        _,objects,_,_,_,stats=pipeline.process(scene(dx=8),self.request(10.1))
        self.assertEqual(len(objects),1)
        self.assertEqual(objects[0]["classificationCaptured"],10)
        self.assertEqual(stats["mode"],"tracking")
        identity=objects[0]["trackID"]
        _,objects,_,_,_,_=pipeline.process(scene(dx=12),dict(self.request(10.2),selectedTrackID=identity))
        self.assertEqual(objects[0]["trackID"],identity)

    def test_classifier_failure_keeps_depth_and_obstacles_active(self):
        detector=FakeDetector(); detector.error="injected classifier failure"
        pipeline=LivePerception(DepthOnly(),detector)
        _,objects,obstacles,coverage,_,stats=pipeline.process(scene(),self.request())
        self.assertEqual(objects,[]); self.assertTrue(obstacles); self.assertEqual(coverage,1)
        self.assertIn("failure",stats["classifierError"])

    def test_classifier_rate_limit_is_independent_of_frame_rate(self):
        clock=[100.]
        called=threading.Event(); calls=[]
        class Backend:
            def detect(self,*args,**kwargs): calls.append(clock[0]); called.set(); return [],[]
        service=DetectionService(Backend(),clock=lambda:clock[0])
        request=self.request()
        try:
            service.offer(scene(),request); self.assertTrue(called.wait(1)); called.clear()
            for i in range(10): service.offer(scene(),dict(request,captured=10+i*.01))
            self.assertFalse(called.wait(.05))
            clock[0]=100.99; service.offer(scene(),request)
            self.assertFalse(called.wait(.05))
            clock[0]=101.; service.offer(scene(),request)
            self.assertTrue(called.wait(1))
            self.assertEqual(calls,[100.,101.])
        finally: service.close()


if __name__ == "__main__": unittest.main()
