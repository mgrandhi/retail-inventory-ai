"""Confidence-gated inference — the mentor's core design.

For each product crop:
    cat, subcat, conf = classifier(crop)          # cheap, fast
    if conf >= THRESHOLD:  use the classifier      # high-confidence path
    else:                  fall back to a GCP VLM   # low-confidence path (also gets product name)

So the expensive VLM runs only on the hard crops, not every crop. The fallback rate (fraction
routed to the VLM) is a headline metric for the report.

Three modes:

1. --tune-threshold : on a labeled val set, sweep thresholds and print
   accuracy-on-accepted vs fallback-rate, so you can pick the operating point. (No VLM calls.)
2. (default) label a directory of crops end-to-end, using the VLM for low-confidence ones.
3. --shelf-image IMG : full pipeline on a raw shelf image (YOLO detect -> crop -> gate).

The VLM fallback reuses autolabel/label_vlm.py's backends (Gemini / Gemma) — GCP only, no OpenAI.

  # pick a threshold:
  python -m classification.infer --tune-threshold --model-dir classification/artifacts/clip_v1 \
      --crops data/crops/val --truth ~/Downloads/product_labels_openai_val_normalized_categories.csv

  # run gated labeling:
  python -m classification.infer --model-dir classification/artifacts/clip_v1 \
      --crops data/crops/test --out classification/preds_test.csv --threshold 0.6 --backend gemini
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

from classification import taxonomy
from classification import classifier_lib as lib

IMG_EXTS = {".jpg", ".jpeg", ".png", ".bmp"}


def load_classifier(model_dir: str, device):
    import torch

    ckpt = torch.load(Path(model_dir) / "classifier.pt", map_location=device)
    tax = taxonomy.load()
    model = lib.make_model(ckpt["backbone"], tax).to(device)
    model.load_state_dict(ckpt["state_dict"])
    model.eval()
    return model, tax


def predict_dir(model, tax, crops, device, preprocess, batch_size=64):
    """Yield (filename, cat_name, sub_name, cat_conf) for each crop."""
    import torch
    from PIL import Image

    for i in range(0, len(crops), batch_size):
        batch = crops[i : i + batch_size]
        imgs, kept = [], []
        for p in batch:
            try:
                imgs.append(preprocess(Image.open(p).convert("RGB"))); kept.append(p)
            except Exception as e:
                print(f"WARN: skip {p.name}: {e}")
        if not imgs:
            continue
        with torch.no_grad():
            x = torch.stack(imgs).to(device)
            cat_logits, sub_logits = model(x)
            cid, cconf, sid, _ = lib.masked_subcategory_pred(cat_logits, sub_logits, tax)
        for b in range(len(kept)):
            yield (kept[b].name,
                   tax.category_names[int(cid[b])],
                   tax.subcategory_names[int(sid[b])],
                   float(cconf[b]))


def load_truth(path):
    with open(path, newline="") as f:
        return {r["filename"]: r for r in csv.DictReader(f) if r.get("filename")}


def tune_threshold(model, tax, crops, device, preprocess, truth):
    """Print accuracy-on-accepted vs fallback-rate across thresholds (no VLM calls)."""
    # Only crops with ground truth contribute to the sweep — predicting the rest is wasted compute
    # (the val crop dir can hold ~92k crops while truth covers ~2k). Filter BEFORE inference.
    crops = [p for p in crops if p.name in truth]
    print(f"{len(crops)} crops have ground truth (predicting only these)")
    preds = list(predict_dir(model, tax, crops, device, preprocess))
    scored = [(fn, c, s, conf) for fn, c, s, conf in preds if fn in truth]
    print(f"{len(scored)} predictions have ground truth\n")
    print(f"{'thresh':>7} {'accept%':>8} {'fallback%':>10} {'acc@accept(cat)':>16} {'acc@accept(sub)':>16} {'overall_cat':>12}")
    rows = []
    for t in [i / 20 for i in range(21)]:  # 0.00 .. 1.00 step 0.05
        accepted = [(fn, c, s, conf) for fn, c, s, conf in scored if conf >= t]
        n_acc = len(accepted)
        cat_ok = sum(1 for fn, c, s, _ in accepted if c == truth[fn][lib.CAT])
        sub_ok = sum(1 for fn, c, s, _ in accepted if s == truth[fn][lib.SUB])
        # "overall" assumes a perfect VLM on the fallback set (upper bound on system accuracy).
        n_fb = len(scored) - n_acc
        overall_cat = (cat_ok + n_fb) / len(scored) if scored else 0
        rows.append({
            "threshold": round(t, 2),
            "accept_rate": round(n_acc / len(scored), 4) if scored else 0,
            "fallback_rate": round(n_fb / len(scored), 4) if scored else 0,
            "acc_accepted_cat": round(cat_ok / n_acc, 4) if n_acc else 0,
            "acc_accepted_sub": round(sub_ok / n_acc, 4) if n_acc else 0,
            "overall_cat_upperbound": round(overall_cat, 4),
        })
        print(f"{t:>7.2f} {100*rows[-1]['accept_rate']:>7.1f}% {100*rows[-1]['fallback_rate']:>9.1f}% "
              f"{rows[-1]['acc_accepted_cat']:>16.4f} {rows[-1]['acc_accepted_sub']:>16.4f} "
              f"{rows[-1]['overall_cat_upperbound']:>12.4f}")
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model-dir", required=True, help="Dir with classifier.pt + label_maps.json.")
    ap.add_argument("--crops", help="Directory of crops to label (modes 1 & 2).")
    ap.add_argument("--shelf-image", help="A raw shelf image to run the full pipeline on (mode 3).")
    ap.add_argument("--weights", help="YOLO detector weights (required for --shelf-image).")
    ap.add_argument("--out", help="Output predictions CSV (mode 2/3).")
    ap.add_argument("--threshold", type=float, default=0.6, help="Confidence gate.")
    ap.add_argument("--tune-threshold", action="store_true", help="Sweep thresholds vs ground truth.")
    ap.add_argument("--truth", help="Ground-truth labels CSV (for --tune-threshold).")
    ap.add_argument("--backend", default="gemini", choices=["gemini", "gemma"], help="VLM fallback backend.")
    ap.add_argument("--device", default=None)
    args = ap.parse_args()

    import torch

    device = args.device or ("cuda" if torch.cuda.is_available() else "cpu")
    model, tax = load_classifier(args.model_dir, device)
    preprocess = model.preprocess

    # --- Mode 3: shelf image -> detect -> crops (written to a temp dir) ---
    crops_dir = args.crops
    tmp_crop_dir = None
    if args.shelf_image:
        if not args.weights:
            raise SystemExit("--shelf-image requires --weights (the YOLO detector).")
        from ultralytics import YOLO
        from PIL import Image
        import tempfile

        tmp_crop_dir = Path(tempfile.mkdtemp(prefix="shelf_crops_"))
        det = YOLO(args.weights)
        res = det.predict(source=args.shelf_image, imgsz=1280, conf=0.25, verbose=False)[0]
        im = Image.open(args.shelf_image).convert("RGB")
        for n, box in enumerate(res.boxes):
            x1, y1, x2, y2 = (int(v) for v in box.xyxy[0].tolist())
            im.crop((x1, y1, x2, y2)).save(tmp_crop_dir / f"shelf_det{n}_crop.jpg", quality=92)
        crops_dir = str(tmp_crop_dir)
        print(f"detected {len(res.boxes)} products -> {crops_dir}")

    crops = sorted(p for p in Path(crops_dir).rglob("*") if p.suffix.lower() in IMG_EXTS)
    print(f"{len(crops)} crops")

    # --- Mode 1: tune threshold ------------------------------------------
    if args.tune_threshold:
        if not args.truth:
            raise SystemExit("--tune-threshold requires --truth.")
        rows = tune_threshold(model, tax, crops, device, preprocess, load_truth(args.truth))
        if args.out:
            Path(args.out).write_text(json.dumps(rows, indent=2))
        return

    # --- Mode 2/3: gated labeling ----------------------------------------
    vlm = None
    from autolabel import label_vlm

    # Lazily build the VLM backend only if we expect fallbacks.
    def get_vlm():
        nonlocal vlm
        if vlm is None:
            ns = argparse.Namespace(backend=args.backend, model=None, project=None, location="us-central1")
            vlm = label_vlm.build_backend(ns, tax.subcategory_names)
        return vlm

    out = args.out or "classification/preds.csv"
    n_clf = n_fb = 0
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["filename", "normalized_category", "normalized_subcategory", "confidence", "product_label", "route"])
        for fn, cat, sub, conf in predict_dir(model, tax, crops, device, preprocess):
            if conf >= args.threshold:
                w.writerow([fn, cat, sub, round(conf, 4), "", "classifier"]); n_clf += 1
            else:
                path = next(p for p in crops if p.name == fn)
                try:
                    vsub, product, _ = get_vlm().label_one(path)
                    if not tax.is_subcategory(vsub):
                        vsub = "Unclear / Generic Product"
                    w.writerow([fn, tax.parent_of(vsub), vsub, round(conf, 4), product, f"vlm:{args.backend}"])
                except Exception as e:
                    print(f"WARN: VLM fallback failed for {fn}: {e}; keeping classifier label")
                    w.writerow([fn, cat, sub, round(conf, 4), "", "classifier(fallback-failed)"])
                n_fb += 1

    total = n_clf + n_fb
    print(f"DONE: {total} crops -> {out}")
    print(f"  classifier-accepted: {n_clf} ({100*n_clf/total:.1f}%)" if total else "  none")
    print(f"  VLM fallback:        {n_fb} ({100*n_fb/total:.1f}%)" if total else "")
    if tmp_crop_dir:
        print(f"  (shelf crops in {tmp_crop_dir})")


if __name__ == "__main__":
    main()
