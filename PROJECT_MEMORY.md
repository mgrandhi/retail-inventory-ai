# PROJECT MEMORY — retail-inventory-ai

> **This is the resume file.** When the user says "resume", read this first, then continue from
> **Status → Next step**. Keep it current at the end of every session.

Last updated: **2026-06-07**

---

## GCP

- **Project ID:** `ehc-mgrandhi-bc801a` · account `mgrandhi@salesforce.com`
- **Region/Zone:** `us-central1` / `us-central1-a`
- **Bucket:** `gs://ehc-mgrandhi-bc801a-sku110k-yolo`

## Status

- **Current phase:** Week 3 — Module 1 (YOLOv8 detection on SKU-110K).
- **Overall:** project scaffolded; detection training infra + checkpoint notebook authored.
- **Done so far:**
  - Project folder scaffolded at `/Users/mgrandhi/Projects/retail-inventory-ai`.
  - GCP L4 training scripts written (`detection/train_sku110k.sh`, `launch_vm.sh`, `teardown.sh`).
  - Colab before/after checkpoint notebook written (`notebooks/01_detection_checkpoint.ipynb`).
  - LaTeX report skeleton scaffolded (`report/`).
- **GCP prereqs DONE (2026-06-06):** authed as mgrandhi@salesforce.com; Compute API enabled;
  bucket `gs://ehc-mgrandhi-bc801a-sku110k-yolo` created; L4 quota=32 (✅), CPUS=5000, SSD=81920.
- **TRAINING DONE (2026-06-07 ~04:23 UTC):** YOLOv8m, time-capped at 9.5h, stopped at epoch 47/50.
  Final val: **mAP@0.5 = 0.9209**, mAP@0.5:0.95 = 0.5937, P = 0.9193, R = 0.8824 — all targets
  smashed. AutoBatch=3 @ imgsz=1280, cos_lr, COCO init. VM `sku110k-train` deleted 2026-06-07.
- **Auto-sync gotcha (fixed):** the VM's default compute SA had no write access to the bucket,
  so the EXIT-trap `gsutil rsync` silently failed and the VM kept running idle. Manually granted
  `roles/storage.objectAdmin` on the bucket to `717517977720-compute@developer.gserviceaccount.com`,
  rsynced from inside the VM, then deleted it. Future `launch_vm.sh` runs need this binding (or
  a `--service-account` flag with a SA that already has it) before training starts.
- **Artifacts in GCS** (`gs://ehc-mgrandhi-bc801a-sku110k-yolo/results/`):
  `best.pt` (49.7 MiB), `last.pt` (49.7 MiB), `metrics.json`, `train.log` (19.9 MiB),
  `sku110k/` (training run dir: results.png, args.yaml, results.csv, curves, batch viz, weights/),
  `sku110k_val/` (final val pass viz).
- **Next step:**
  1. Run `notebooks/01_detection_checkpoint.ipynb` for before/after panels (downloads `best.pt`).
  2. Copy `results.png` + before/after panels into `report/figures/`.
  3. Update `report/sections/06_results.tex` with the numbers above (replace TBDs).
  4. Move on to Module 2 (Week 4 — classification: ResNet-50 + CLIP on RPC).

## The 8-week arc (from proposal)

| Week | Focus |
|---|---|
| 1 | Environment setup + literature review |
| 2 | EDA + data preprocessing |
| **3** | **YOLOv8 detection training (SKU-110K) ← we are here** |
| 4 | Classification (ResNet-50 + CLIP, RPC dataset) |
| 5 | Auto-labeling (LLaVA) + FastAPI/SQLite backend |
| 6 | LLM business-intelligence interface (LangGraph + Ollama) |
| 7 | Streamlit dashboard + integration |
| 8 | Deployment (Cloud Run + Heroku) + report + presentation |

## Evaluation targets (detection)

| Metric | Target |
|---|---|
| mAP@0.5 | ≥ 0.70 |
| mAP@0.5:0.95 | reported |
| Precision / Recall | ≥ 0.75 / ≥ 0.70 |

## Key decisions (see DECISIONS.md for full rationale)

- GPU: **1× NVIDIA L4** (`g2-standard-8`), not T4/P4 — ~2–3× T4 for ~same total cost under a time cap.
- Wall-clock bounded by Ultralytics `time=9.5` (hard cap), not a fixed epoch count.
- VM **auto-deletes** after syncing results to GCS → bounded cost (~$8–9/run).
- Colab notebook does **inference only** (downloads `best.pt` from GCS); GCP does the real training.

## Open issues

- See `ISSUES.md`. None blocking as of last update.

## Latest results

- Detection (YOLOv8m, SKU-110K, imgsz=1280, time=9.5h, AutoBatch=3, COCO init):
  **mAP@0.5 = 0.9209**, mAP@0.5:0.95 = 0.5937, P = 0.9193, R = 0.8824, epoch 47/50.
  See `RESULTS.md` for the row + `gs://ehc-mgrandhi-bc801a-sku110k-yolo/results/` for artifacts.

## How to resume (commands)

```bash
cd /Users/mgrandhi/Projects/retail-inventory-ai
cat PROJECT_MEMORY.md        # this file
tail -n 30 DECISIONS.md ISSUES.md RESULTS.md
# detection training:
source .env                  # PROJECT_ID, BUCKET, ZONE
gcloud compute instances list   # is a training VM still running?
gsutil ls gs://${PROJECT_ID}-sku110k-yolo/results/ 2>/dev/null  # are results in yet?
```
