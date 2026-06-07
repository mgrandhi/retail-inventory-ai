# Results Log

Append-only experiment ledger. This table is transcribed directly into the report's Results
section (LaTeX `tabular`). One row per experiment run.

---

## Detection (Module 1 — YOLOv8m on SKU-110K)

| Date | Model | Config | mAP@0.5 | mAP@0.5:0.95 | Precision | Recall | Notes |
|---|---|---|---|---|---|---|---|
| 2026-06-06 → 2026-06-07 | YOLOv8m | imgsz=1280, time=9.5h, batch=3 (AutoBatch), cos_lr, COCO-init | **0.9209** | **0.5937** | **0.9193** | **0.8824** | GCP L4 (g2-standard-8); 8216 train / 588 val (corrupt JPEGs auto-restored); time-cap stopped at epoch 47/50; artifacts in `gs://ehc-mgrandhi-bc801a-sku110k-yolo/results/` (`best.pt`, `last.pt`, `metrics.json`, `train.log`, `sku110k/`, `sku110k_val/`) |

> Targets: mAP@0.5 ≥ 0.70 · Precision ≥ 0.75 · Recall ≥ 0.70.

## Classification (Module 2 — ResNet-50 + CLIP on RPC) — Week 4
_not started_

## Auto-labeling (Module 3 — LLaVA) — Week 5
_not started_

## NL BI interface (Module 5) — Week 6
_not started_

## System-level — Week 7+
_not started_
