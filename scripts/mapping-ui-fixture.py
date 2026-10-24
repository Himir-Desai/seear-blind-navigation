"""Synthetic QA only: render known room planes into the native debug snapshot."""
import json
from pathlib import Path
import sys
import time
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"vision/tests"))
from test_mapping import GEOMETRY, initial_pose, rendered_room, empty_floorplan, integrate_floorplan

plan=empty_floorplan()
path=[]
for x in [0,.12,.24]:
    pose=initial_pose(GEOMETRY); pose[0,3]=x
    depth,camera,semantic=rendered_room(pose)
    integrate_floorplan(plan,depth,GEOMETRY,camera,pose,semantic)
    path.append(pose[:3,3].tolist())
snapshot=dict(status="tracking",updated=time.monotonic(),mapID="synthetic-ui-only",landmarks=0,confirmed=0,
    savedMaps=0,keyframes=0,position=path[-1],heading=pose[:3,2].tolist(),points=[],path=path,
    inliers=0,units="estimated_meters",detail="SYNTHETIC QA ROOM — not a physical camera scan",resolution=.15,
    floor=plan["floor"],occupied=plan["occupied"],walls=[{k:w[k] for k in ("start","end","observations")} for w in plan["walls"]])
root=Path(__file__).resolve().parents[1]
(root/"build").mkdir(exist_ok=True)
(root/"build/map-ui-fixture.json").write_text(json.dumps(snapshot,allow_nan=False))
print("Synthetic mapping UI fixture ready")
