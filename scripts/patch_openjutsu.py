"""The shipped Fix faces workflow uses Windows path separators for its YOLO detectors.
On Linux ComfyUI lists them as bbox/... and segm/..., so rewrite the two values."""
from pathlib import Path

path = Path("/opt/openjutsu/workflows/face.api.json")
text = path.read_text(encoding="utf-8")
patched = (
    text.replace("bbox\\\\face_yolov8m.pt", "bbox/face_yolov8m.pt")
        .replace("segm\\\\person_yolov8m-seg.pt", "segm/person_yolov8m-seg.pt")
)
path.write_text(patched, encoding="utf-8")
print("face.api.json:", "detector paths patched" if patched != text else "no change needed")
