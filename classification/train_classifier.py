"""Train the two-head crop classifier (category + subcategory) over the fixed taxonomy.

This is the high-confidence path of the mentor's design: a cheap classifier that handles the
easy crops, leaving only low-confidence crops for the LLM fallback (classification/infer.py).

Targets the NORMALIZED taxonomy (18 cats / 48 subcats) — NOT the ~9.7k product names, which
is why the teammate's product-name classifier scored near-zero. These classes are learnable.

Inputs:
  --train-labels  CSV (filename, normalized_category, normalized_subcategory, ...) from a labeler
  --train-crops   directory of the corresponding crop images
  --val-labels / --val-crops   evaluation set (e.g. val crops + the shared ground-truth CSV)

Handles class imbalance with a weighted sampler. Saves classifier.pt, label_maps.json, and
metrics.json (per-head top-1 / top-3 / macro-F1) to --out.

Runs on the GCP GPU VM (classification/train_classifier.sh) or CPU for a 10%-subset smoke test.

  python -m classification.train_classifier --backbone clip \
      --train-labels autolabel/labels_clip_train.csv --train-crops data/crops/train \
      --val-labels ~/Downloads/product_labels_openai_val_normalized_categories.csv \
      --val-crops data/crops/val --out classification/artifacts/clip_v1
"""
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

from classification import taxonomy
from classification import classifier_lib as lib


def make_sampler(cat_labels, n_cat):
    """Inverse-frequency weighted sampler over the category head to fight imbalance."""
    import torch
    from torch.utils.data import WeightedRandomSampler

    counts = Counter(cat_labels)
    weights = [1.0 / counts[c] for c in cat_labels]
    return WeightedRandomSampler(torch.tensor(weights, dtype=torch.double), num_samples=len(cat_labels), replacement=True)


def evaluate(model, loader, tax, device):
    import torch
    from sklearn.metrics import f1_score

    model.eval()
    cat_correct = cat_top3 = sub_correct = total = 0
    cat_true, cat_pred, sub_true, sub_pred = [], [], [], []
    with torch.no_grad():
        for imgs, cat_id, sub_id in loader:
            imgs = imgs.to(device)
            cat_logits, sub_logits = model(imgs)
            # top-3 category
            top3 = cat_logits.topk(3, dim=-1).indices.cpu()
            pc, pcc, ps, _ = lib.masked_subcategory_pred(cat_logits, sub_logits, tax)
            pc, ps = pc.cpu(), ps.cpu()
            for b in range(cat_id.shape[0]):
                total += 1
                cat_correct += int(pc[b] == cat_id[b])
                cat_top3 += int(cat_id[b] in top3[b])
                sub_correct += int(ps[b] == sub_id[b])
                cat_true.append(int(cat_id[b])); cat_pred.append(int(pc[b]))
                sub_true.append(int(sub_id[b])); sub_pred.append(int(ps[b]))
    return {
        "n": total,
        "cat_top1": round(cat_correct / total, 4) if total else 0,
        "cat_top3": round(cat_top3 / total, 4) if total else 0,
        "sub_top1": round(sub_correct / total, 4) if total else 0,
        "cat_macro_f1": round(float(f1_score(cat_true, cat_pred, average="macro", zero_division=0)), 4),
        "sub_macro_f1": round(float(f1_score(sub_true, sub_pred, average="macro", zero_division=0)), 4),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backbone", default="clip", choices=["clip", "resnet50"])
    ap.add_argument("--train-labels", required=True)
    ap.add_argument("--train-crops", required=True)
    ap.add_argument("--val-labels", required=True)
    ap.add_argument("--val-crops", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--epochs", type=int, default=15)
    ap.add_argument("--batch-size", type=int, default=64)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--device", default=None)
    args = ap.parse_args()

    import torch
    import torch.nn as nn
    from torch.utils.data import DataLoader

    tax = taxonomy.load()
    device = args.device or ("cuda" if torch.cuda.is_available() else "cpu")
    out_dir = Path(args.out); out_dir.mkdir(parents=True, exist_ok=True)
    print(f"backbone={args.backbone} device={device}")

    model = lib.make_model(args.backbone, tax).to(device)
    preprocess = model.preprocess

    train_ds = lib.CropDataset(args.train_labels, args.train_crops, preprocess, tax)
    val_ds = lib.CropDataset(args.val_labels, args.val_crops, preprocess, tax)
    print(f"train={len(train_ds)} crops  val={len(val_ds)} crops")

    sampler = make_sampler(train_ds.category_labels(), tax.n_categories)
    train_loader = DataLoader(train_ds, batch_size=args.batch_size, sampler=sampler, num_workers=args.workers)
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False, num_workers=args.workers)

    # Only optimize params that require grad (CLIP backbone is frozen).
    params = [p for p in model.parameters() if p.requires_grad]
    opt = torch.optim.AdamW(params, lr=args.lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)
    loss_fn = nn.CrossEntropyLoss()

    best = {"cat_top1": -1.0}
    history = []
    for epoch in range(args.epochs):
        model.train()
        running = 0.0
        for imgs, cat_id, sub_id in train_loader:
            imgs, cat_id, sub_id = imgs.to(device), cat_id.to(device), sub_id.to(device)
            cat_logits, sub_logits = model(imgs)
            loss = loss_fn(cat_logits, cat_id) + loss_fn(sub_logits, sub_id)
            opt.zero_grad(); loss.backward(); opt.step()
            running += float(loss)
        sched.step()
        metrics = evaluate(model, val_loader, tax, device)
        metrics["epoch"] = epoch; metrics["train_loss"] = round(running / max(1, len(train_loader)), 4)
        history.append(metrics)
        print(f"epoch {epoch}: loss={metrics['train_loss']} "
              f"cat_top1={metrics['cat_top1']} cat_top3={metrics['cat_top3']} "
              f"sub_top1={metrics['sub_top1']} cat_F1={metrics['cat_macro_f1']}")
        if metrics["cat_top1"] > best["cat_top1"]:
            best = metrics
            torch.save({
                "state_dict": model.state_dict(),
                "backbone": args.backbone,
                "n_cat": tax.n_categories, "n_sub": tax.n_subcategories,
            }, out_dir / "classifier.pt")

    (out_dir / "label_maps.json").write_text(json.dumps({
        "category_names": tax.category_names,
        "subcategory_names": tax.subcategory_names,
    }, indent=2))
    (out_dir / "metrics.json").write_text(json.dumps({
        "backbone": args.backbone,
        "best": best,
        "history": history,
    }, indent=2))
    print(f"\nDONE: best cat_top1={best['cat_top1']} sub_top1={best['sub_top1']} -> {out_dir}")


if __name__ == "__main__":
    main()
