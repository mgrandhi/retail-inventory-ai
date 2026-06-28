"""Generate per-product crops from SKU-110K shelf images using our trained detector.

Module 2 (classification) trains on individual product crops, but SKU-110K ships as full
shelf images. This script runs our fine-tuned YOLO detector (detection/artifacts/v11/best.pt,
mAP@0.5 ~0.92) over the shelf images, crops every detected box, and writes:

  <out>/<split>/<split>_<imgidx>_det<n>_crop.jpg     one file per detected product
  <out>/crops_manifest.csv                           filename, source, bbox, det conf, split

The crop filename pattern matches the teammate's val export (`val_102_det0_crop.jpg`) so the
shared val labels CSV joins straight onto our val crops by `filename`.

10%-FIRST: `--fraction 0.10` (default) samples 10% of the *train* shelf images (deterministic,
seeded) while keeping ALL of val/test, so we validate the whole pipeline cheaply before paying
to crop + label the full set. Bump to 0.5 / 1.0 once the 10% metrics look good.

Runs anywhere Ultralytics + the weights are available — locally for a smoke test, or on the
GCP VM via classification/crop_sku110k.sh (inference-only, so a cheap GPU or even CPU is fine).
"""
from __future__ import annotations

import argparse
import csv
import random
import re
from pathlib import Path

# Imported lazily inside main() so `--help` works without the heavy deps installed:
#   from ultralytics import YOLO
#   from PIL import Image

IMG_EXTS = {".jpg", ".jpeg", ".png", ".bmp"}
SPLITS = ("train", "val", "test")


def find_split_images(images_root: Path) -> dict[str, list[Path]]:
    """Locate shelf images per split.

    SKU-110K_fixed lays images out as images/<split>_*.jpg in a single dir; some mirrors use
    images/<split>/. Handle both: bucket by the split token in the path/filename.
    """
    by_split: dict[str, list[Path]] = {s: [] for s in SPLITS}
    for p in sorted(images_root.rglob("*")):
        if p.suffix.lower() not in IMG_EXTS:
            continue
        # Prefer a parent dir named exactly after a split; else match the filename prefix.
        parts = {x.lower() for x in p.parts}
        hit = next((s for s in SPLITS if s in parts), None)
        if hit is None:
            name = p.name.lower()
            hit = next((s for s in SPLITS if name.startswith(s)), None)
        if hit:
            by_split[hit].append(p)
    return by_split


def sample_train(images: list[Path], fraction: float, seed: int) -> list[Path]:
    """Deterministically keep `fraction` of the train images (all of them if fraction>=1)."""
    if fraction >= 1.0:
        return images
    k = max(1, int(round(len(images) * fraction)))
    rng = random.Random(seed)
    return sorted(rng.sample(images, k))


def crop_split(model, image_paths, split, out_dir, manifest_writer, *, imgsz, conf, min_box):
    """Detect on each shelf image, crop every box, save crops, append manifest rows."""
    from PIL import Image

    split_dir = out_dir / split
    split_dir.mkdir(parents=True, exist_ok=True)
    n_crops = 0
    for img_path in image_paths:
        # Crop names MUST key off the source image's OWN number (val_102.jpg -> val_102_detN),
        # NOT a 0-based enumerate() counter — the teammate's shared val labels are named that way,
        # and only this makes `filename` join correctly onto their ground-truth CSV. (A loop
        # counter silently shifts indices when train images are sampled, producing a filename
        # collision against unrelated crops.)
        m = re.search(r"(\d+)", img_path.stem)
        img_idx = m.group(1) if m else img_path.stem.replace(split, "").strip("_") or "0"
        # imgsz/conf match the detector's training regime; verbose=False keeps logs sane.
        results = model.predict(source=str(img_path), imgsz=imgsz, conf=conf, verbose=False)
        if not results:
            continue
        res = results[0]
        try:
            im = Image.open(img_path).convert("RGB")
        except Exception as e:  # corrupt JPEG, etc. — skip, don't kill the run
            print(f"WARN: cannot open {img_path}: {e}")
            continue
        W, H = im.size
        boxes = res.boxes
        if boxes is None:
            continue
        for det_n, box in enumerate(boxes):
            x1, y1, x2, y2 = (float(v) for v in box.xyxy[0].tolist())
            det_conf = float(box.conf[0]) if box.conf is not None else 0.0
            # Clamp to image bounds and drop degenerate / tiny boxes.
            x1, y1 = max(0, int(x1)), max(0, int(y1))
            x2, y2 = min(W, int(x2)), min(H, int(y2))
            if (x2 - x1) < min_box or (y2 - y1) < min_box:
                continue
            crop_name = f"{split}_{img_idx}_det{det_n}_crop.jpg"
            im.crop((x1, y1, x2, y2)).save(split_dir / crop_name, quality=92)
            manifest_writer.writerow(
                [crop_name, img_path.name, split, x1, y1, x2, y2, round(det_conf, 4)]
            )
            n_crops += 1
    print(f"  {split}: {len(image_paths)} images -> {n_crops} crops")
    return n_crops


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--weights", required=True, help="Path to YOLO best.pt (the detector).")
    ap.add_argument("--images-root", required=True, help="SKU-110K images root (train/val/test).")
    ap.add_argument("--out", required=True, help="Output dir for crops/ + crops_manifest.csv.")
    ap.add_argument("--fraction", type=float, default=0.10, help="Fraction of TRAIN images (val/test always full). Default 0.10.")
    ap.add_argument("--seed", type=int, default=42, help="Seed for deterministic train sampling.")
    ap.add_argument("--imgsz", type=int, default=1280, help="Detector inference image size.")
    ap.add_argument("--conf", type=float, default=0.25, help="Detection confidence threshold.")
    ap.add_argument("--min-box", type=int, default=8, help="Drop boxes smaller than this (px) on either side.")
    ap.add_argument("--splits", nargs="+", default=list(SPLITS), choices=SPLITS, help="Which splits to crop.")
    args = ap.parse_args()

    from ultralytics import YOLO

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    model = YOLO(args.weights)

    by_split = find_split_images(Path(args.images_root))
    for s in SPLITS:
        print(f"found {len(by_split[s])} {s} images")

    manifest_path = out_dir / "crops_manifest.csv"
    total = 0
    with open(manifest_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["filename", "source_image", "split", "x1", "y1", "x2", "y2", "det_conf"])
        for split in args.splits:
            imgs = by_split[split]
            if split == "train":
                imgs = sample_train(imgs, args.fraction, args.seed)
                print(f"train sampled to {len(imgs)} images (fraction={args.fraction}, seed={args.seed})")
            if not imgs:
                continue
            total += crop_split(
                model, imgs, split, out_dir, w,
                imgsz=args.imgsz, conf=args.conf, min_box=args.min_box,
            )

    print(f"\nDONE: {total} crops -> {out_dir}  (manifest: {manifest_path})")


if __name__ == "__main__":
    main()
