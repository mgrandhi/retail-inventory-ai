"""Zero-shot crop labeler using CLIP — FREE, no API, runs on the crop VM or locally.

For each product crop, encode the image with open-clip and score it against text prompts
built from the fixed taxonomy (classification/taxonomy.py). Two passes:

  1. CATEGORY: softmax over the 18 category prompts -> top category + its probability.
  2. SUBCATEGORY: softmax over ONLY the subcategory prompts that belong to the chosen
     category (the taxonomy is a clean tree), so the subcategory is always consistent with
     the category. For single-subcategory categories this is automatic.

`confidence` = the category softmax max (the gate-style signal we later compare to the VLM
and use to decide CLIP-vs-VLM for the full set). Output schema = autolabel/labelio.py.

Usage:
  python -m autolabel.label_clip --crops data/crops/val --out autolabel/labels_clip_val.csv
"""
from __future__ import annotations

import argparse
from pathlib import Path

from classification import taxonomy
from autolabel import labelio

IMG_EXTS = {".jpg", ".jpeg", ".png", ".bmp"}


def iter_crops(crops_dir: Path):
    for p in sorted(crops_dir.rglob("*")):
        if p.suffix.lower() in IMG_EXTS:
            yield p


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--crops", required=True, help="Directory of crop images (recursed).")
    ap.add_argument("--out", required=True, help="Output labels CSV (resumable — appends).")
    ap.add_argument("--model", default="ViT-B-32", help="open-clip model name.")
    ap.add_argument("--pretrained", default="laion2b_s34b_b79k", help="open-clip pretrained tag.")
    ap.add_argument("--batch-size", type=int, default=64)
    ap.add_argument("--device", default=None, help="cuda|cpu (auto if unset).")
    ap.add_argument("--cat-template", default="a retail product, category: {}")
    ap.add_argument("--sub-template", default="a retail product, type: {}")
    args = ap.parse_args()

    import torch
    import open_clip
    from PIL import Image

    tax = taxonomy.load()
    device = args.device or ("cuda" if torch.cuda.is_available() else "cpu")
    print(f"device={device}  model={args.model}/{args.pretrained}")

    model, _, preprocess = open_clip.create_model_and_transforms(
        args.model, pretrained=args.pretrained
    )
    model = model.to(device).eval()
    tokenizer = open_clip.get_tokenizer(args.model)

    # Precompute normalized text features for category + subcategory prompts (once).
    @torch.no_grad()
    def encode_text(prompts: list[str]) -> "torch.Tensor":
        toks = tokenizer(prompts).to(device)
        feats = model.encode_text(toks)
        return feats / feats.norm(dim=-1, keepdim=True)

    cat_prompts = tax.category_prompts(args.cat_template)
    sub_prompts = tax.subcategory_prompts(args.sub_template)
    cat_text = encode_text(cat_prompts)            # [18, D]
    sub_text = encode_text(sub_prompts)            # [48, D]

    # Map each category id -> the column indices of its subcategories within sub_text.
    cat_to_sub_idx = {
        ci: tax.subcategory_ids_of(cat) for ci, cat in enumerate(tax.category_names)
    }

    done = labelio.already_labeled(args.out)
    crops = [p for p in iter_crops(Path(args.crops)) if p.name not in done]
    print(f"{len(crops)} crops to label ({len(done)} already done)")

    f, writer = labelio.open_writer(args.out)
    n = 0
    try:
        for i in range(0, len(crops), args.batch_size):
            batch_paths = crops[i : i + args.batch_size]
            imgs, kept = [], []
            for p in batch_paths:
                try:
                    imgs.append(preprocess(Image.open(p).convert("RGB")))
                    kept.append(p)
                except Exception as e:
                    print(f"WARN: skip {p.name}: {e}")
            if not imgs:
                continue
            with torch.no_grad():
                x = torch.stack(imgs).to(device)
                img_feat = model.encode_image(x)
                img_feat = img_feat / img_feat.norm(dim=-1, keepdim=True)

                # Pass 1 — category over all 18.
                cat_logits = (100.0 * img_feat @ cat_text.T).softmax(dim=-1)  # [B,18]
                cat_conf, cat_id = cat_logits.max(dim=-1)

                # Pass 2 — subcategory restricted to the chosen category's children.
                for b in range(len(kept)):
                    ci = int(cat_id[b])
                    cat_name = tax.category_names[ci]
                    sub_cols = cat_to_sub_idx[ci]
                    if len(sub_cols) == 1:
                        sub_name = tax.subcategory_names[sub_cols[0]]
                    else:
                        sub_scores = (100.0 * img_feat[b : b + 1] @ sub_text[sub_cols].T)
                        sub_scores = sub_scores.softmax(dim=-1)
                        best = int(sub_scores.argmax())
                        sub_name = tax.subcategory_names[sub_cols[best]]
                    writer.writerow({
                        "filename": kept[b].name,
                        "normalized_category": cat_name,
                        "normalized_subcategory": sub_name,
                        "confidence": round(float(cat_conf[b]), 4),
                        "source": "clip",
                    })
                    n += 1
            f.flush()
            print(f"  labeled {n}/{len(crops)}")
    finally:
        f.close()
    print(f"DONE: wrote {n} labels -> {args.out}")


if __name__ == "__main__":
    main()
