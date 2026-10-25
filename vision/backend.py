"""Replaceable local detector + metric monocular-depth backend. No remote inference."""
import os
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DETECTOR = "google/owlv2-base-patch16-ensemble"
DEPTH = "depth-anything/Depth-Anything-V2-Metric-Indoor-Small-hf"
SEGMENTATION = "nvidia/segformer-b0-finetuned-ade-512-512"
REVISIONS = {DETECTOR: "cfd3195ba4ea9592eec887ded089f4c08eff231d",
             DEPTH: "8078d68a9c75a972131914f6afd0c1723be0da7f",
             SEGMENTATION: "489d5cd81a0b59fab9b7ea758d3548ebe99677da"}


def cache_root():
    return Path(os.environ.get("SEEAR_MODELS", str(ROOT / "models")))


def download_models():
    from huggingface_hub import snapshot_download
    for repo in (DETECTOR, DEPTH, SEGMENTATION):
        snapshot_download(repo, revision=REVISIONS[repo], cache_dir=str(cache_root()),
                          allow_patterns=["*.json", "*.txt", "*.safetensors", "*.model"])


class LocalVision:
    def __init__(self):
        import torch
        from transformers import (Owlv2Processor, Owlv2ForObjectDetection,
                                  AutoImageProcessor, AutoModelForDepthEstimation)
        self.torch = torch
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.detector_dtype = torch.float16 if self.device == "mps" else torch.float32
        torch.set_num_threads(4)
        args = dict(cache_dir=str(cache_root()), local_files_only=True)
        self.detector_processor = Owlv2Processor.from_pretrained(DETECTOR, revision=REVISIONS[DETECTOR], use_fast=False, **args)
        self.detector = Owlv2ForObjectDetection.from_pretrained(DETECTOR, revision=REVISIONS[DETECTOR], use_safetensors=True, **args).to(device=self.device,dtype=self.detector_dtype).eval()
        self.depth_processor = AutoImageProcessor.from_pretrained(DEPTH, revision=REVISIONS[DEPTH], use_fast=False, **args)
        self.depth_model = AutoModelForDepthEstimation.from_pretrained(DEPTH, revision=REVISIONS[DEPTH], use_safetensors=True, **args).to(self.device).eval()
        # Pay Metal graph compilation at startup, before publishing fresh scene results.
        from PIL import Image
        warm = Image.new("RGB", (640, 480), "gray")
        self.infer(warm,"white cane")
        self.infer_wearer(warm,"")
        self.infer_wearer(warm,"white cane")

    def infer(self, image, target):
        depth,objects,_ = self._infer(image,target,False)
        return depth,objects

    def infer_wearer(self, image, target):
        return self._infer(image,target,True)

    def _infer(self, image, target, wearer):
        depth = self.estimate_depth(image)
        objects,body = self.detect(image,target,wearer)
        return depth,objects,body

    def estimate_depth(self, image):
        torch = self.torch
        with torch.inference_mode():
            inputs = self.depth_processor(images=image, return_tensors="pt").to(self.device)
            prediction = self.depth_model(**inputs).predicted_depth
            return torch.nn.functional.interpolate(prediction.unsqueeze(1), size=(image.height, image.width),
                mode="bilinear", align_corners=False)[0, 0].cpu().numpy()

    def detect(self, image, target, wearer=False):
        """Only the background classifier calls this; depth has an independent model."""
        from types import SimpleNamespace
        torch = self.torch
        detections,body = [],[]
        queries = ([target] if target else []) + (["shoe","leg"] if wearer else [])
        if not queries:
            return detections,body
        with torch.inference_mode():
            prompts = [["a photo of a " + label for label in queries]]
            inputs = self.detector_processor(text=prompts, images=image, return_tensors="pt").to(self.device)
            inputs = {key: value.to(dtype=self.detector_dtype) if value.is_floating_point() else value
                      for key, value in inputs.items()}
            output = self.detector(**inputs)
            from torchvision.ops import nms
            for query,label in enumerate(queries):
                result = self.detector_processor.post_process_grounded_object_detection(
                    SimpleNamespace(logits=output.logits[:,:,query:query+1],pred_boxes=output.pred_boxes),threshold=.15,
                    target_sizes=torch.tensor([[image.height,image.width]],device=self.device))[0]
                boxes,scores = result["boxes"].float().cpu(),result["scores"].float().cpu()
                destination = detections if target and query == 0 else body
                for i in nms(boxes,scores,.4)[:8]:
                    box = boxes[i].numpy()/np.array([image.width,image.height]*2)
                    destination.append(dict(label=label,confidence=float(scores[i]),box=box.tolist()))
        return detections,body
