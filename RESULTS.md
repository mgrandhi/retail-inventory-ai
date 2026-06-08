# Results Log

Append-only experiment ledger. This table is transcribed directly into the report's Results
section (LaTeX `tabular`). One row per experiment run.

---

## Detection (Module 1 — YOLOv8m on SKU-110K)

| Date | Model | Config | mAP@0.5 | mAP@0.5:0.95 | Precision | Recall | Notes |
|---|---|---|---|---|---|---|---|
| 2026-06-06 → 2026-06-07 | YOLOv8m  | imgsz=1280, time=9.5h, batch=3 (AutoBatch), cos_lr, COCO-init | **0.9209** | **0.5937** | **0.9193** | **0.8824** | GCP L4 (g2-standard-8); 8216 train / 588 val (corrupt JPEGs auto-restored); time-cap stopped at epoch 47/50; artifacts in `gs://…/results/v8/` + repo `detection/artifacts/v8/` |
| 2026-06-07 → 2026-06-08 | YOLOv11m | imgsz=1280, time=8.0h, batch (AutoBatch), cos_lr, COCO-init  | **0.9209** | **0.5941** | **0.9206** | **0.8815** | GCP L4 (g2-standard-8); same data; **no public IP** (Cloud NAT egress); time-cap stopped at epoch 35/50; artifacts in `gs://…/results/v11/` + repo `detection/artifacts/v11/`. Same accuracy as v8 in 1.5h less wall-clock. |

> Targets: mAP@0.5 ≥ 0.70 · Precision ≥ 0.75 · Recall ≥ 0.70.

## Classification (Module 2 — ResNet-50 + CLIP on RPC) — Week 4
_not started_

## Auto-labeling (Module 3 — LLaVA) — Week 5
_not started_

## NL BI interface (Module 5) — Week 6
_not started_

## System-level — Week 7+
_not started_
