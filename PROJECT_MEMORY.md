# PROJECT MEMORY — retail-inventory-ai

> **This is the resume file.** When the user says "resume", read this first, then continue from
> **Status → Next step**. Keep it current at the end of every session.

Last updated: **2026-06-28**

---

## GCP

- **Project ID:** `ehc-mgrandhi-bc801a` · account `mgrandhi@salesforce.com`
- **Region/Zone:** `us-central1` / `us-central1-a`
- **Buckets:**
  - `gs://ehc-mgrandhi-bc801a-sku110k-yolo` — training results (per-variant subdirs)
  - `gs://ehc-mgrandhi-bc801a-datasets` — pre-downloaded dataset cache (see `datasets/README.md`)
- **Cloud NAT** in `us-central1` — required because all VMs are no-public-IP.

## Datasets cache

Pre-downloaded once into `gs://ehc-mgrandhi-bc801a-datasets`. Future training VMs
`gsutil cp` from it instead of re-downloading from public CDNs through Cloud NAT.

| Dataset    | Module          | Bucket prefix | Status       |
|------------|-----------------|---------------|--------------|
| SKU-110K   | Detection (W3)  | `sku110k/`    | **fetched 2026-06-08** (23.5 GiB; tarball + full extracted tree) |
| COCO 2017  | Detection (W3+) | `coco2017/`   | **fetched 2026-06-08** (46.8 GiB; all 5 zips + extracted train2017/test2017 — val/annotations unzip from `zips/` on demand) |
| RPC        | Classification (W4) | `rpc/`    | **fetched 2026-06-12** (25.3 GiB; `rpc/raw/rpc.zip`, unzip on demand) |

See `datasets/README.md` for the layout, fetcher pattern, and how to add a new dataset.

## Status

- **Current phase:** Week 4 — Module 2 (classification: confidence-gated cat/subcat + VLM fallback).
- **Module 2 design (2026-06-27):** mentor reframed it — train a cheap classifier, gate on its
  confidence, fall back to an LLM only for low-confidence crops. KEY FINDING from the shared val
  CSV (`~/Downloads/product_labels_openai_val_normalized_categories.csv`, 15k crops): `product_label`
  has **9,685 unique values** (~1.5 ex each → unlearnable, this is why the teammate's accuracy was
  near-zero). So the classifier targets the **normalized taxonomy: 18 categories / 48 subcategories**
  (learnable); product name is left to the VLM fallback only.
- **All in GCP, NO OpenAI:** labeler + fallback use **Vertex AI Gemini** (`$VERTEX_MODEL`,
  default `gemini-2.5-flash`, verified callable in-project 2026-06-27 — gemini-3.x 404s here; gemini-2.5-flash-lite is the cheap alt) or
  self-hosted **Gemma 3** via Ollama. Auth = VM service account (`roles/aiplatform.user`), no API key.
- **Code scaffolded (2026-06-27), not yet run on GCP:**
  - `classification/taxonomy.py` + `taxonomy.json` — 18/48 single source of truth (verified: clean
    tree, regenerates identically from the val CSV).
  - `classification/gen_crops.py` + `crop_sku110k.sh` + `launch_crops.sh` — detect (v11 best.pt) →
    crop SKU-110K → GCS. `--fraction 0.10` first.
  - `autolabel/label_clip.py` (free), `autolabel/label_vlm.py` (`--backend gemini|gemma`),
    `autolabel/compare_labels.py` (decision gate vs CLIP + vs ground truth).
  - `classification/classifier_lib.py` + `train_classifier.py` + `.sh` + `launch_train.sh` — two-head
    (CLIP-frozen baseline / ResNet-50) classifier.
  - `classification/infer.py` — confidence-gated inference + `--tune-threshold`.
  - All compile; pure helpers unit-tested locally. Heavy runs go on GCP (need torch/open-clip).
- **GCP PROGRESS (2026-06-27):**
  - ✅ **Crops generated** — `sku110k-crops` VM (T4, n1-standard-8) ran `gen_crops.py` at
    `--fraction 0.10`. **673,421 crops**: train 127,706 (822 imgs ≈10%), val 92,597 (588 imgs, full),
    test 453,118 (2934 imgs, full); ~155 crops/img; det_conf mean 0.70. Manifest +
    sample crops verified clean. **Upload to `gs://…-sku110k-yolo/crops/{train,val,test}/` is SLOW**
    (673k tiny files ≈1 MiB/s, ~75 min; rsync order test→train→val so **val lands last**). VM
    self-deletes when the rsync completes. NEXT TIME: tar crops before upload (see memory).
  - ✅ **Vertex prereqs DONE:** `aiplatform.googleapis.com` enabled; compute SA
    `717517977720-compute@developer.gserviceaccount.com` granted `roles/aiplatform.user` (via
    Console — beware the lookalike `service-…@compute-system` agent; the VM uses the `…-compute@developer` one).
  - ✅ **Model verified:** `gemini-2.5-flash` is callable (gemini-3.x 404s in this project);
    `VERTEX_MODEL` updated everywhere. Image+JSON-schema labeling tested end-to-end against a real
    crop (correct label). Added `thinking_budget=0` to GeminiBackend — kills ~136 "thoughts"
    tokens/crop (~34% cost). Projected: val 92k ≈ $11, all 673k ≈ $81 (thinking off).
  - ✅ **New labeling VM scripts:** `autolabel/label_sku110k.sh` + `autolabel/launch_labels.sh`
    (labels val crops with CLIP + Gemini, IAM precheck, self-delete trap). Syntax-checked.
  - ✅ **Crops tarred to GCS (2026-06-27):** per-file upload was too slow, so crops were tarred on
    the VM and streamed as single objects — `$BUCKET/crops/{train,val}_crops.tar` (963 MB / 711 MB)
    + `crops_manifest.csv`. All crop-gen/label VMs now pull + extract these tarballs (100× faster).
  - ✅ **Decision gate DONE (2026-06-27):** Gemini chosen over CLIP. Visual spot-check Gemini 4/4 vs
    CLIP 1/4; CLIP↔Gemini agreement only cat 24.2% / sub 18.4%. (Per-crop accuracy vs the teammate's
    val CSV is NOT a valid join — different detector + box ordering; see RESULTS.md warning.)
  - ✅ **Train labels DONE (2026-06-28):** `sku110k-labels-train` (e2-standard-8 CPU, 32 workers)
    Gemini-labeled **30,000 train crops**, 0 errors, 27.9M tokens, 779 s, 38.5 crops/s →
    `$BUCKET/labels/labels_gemini_train.csv`. Mix: 44% "Other/Unclear", 56% across 17 real cats.
  - ✅ **Classifier TRAINED (2026-06-28):** CLIP-frozen + 2 heads, 15 epochs on L4 (us-central1-c —
    a/b were L4-stockout). Best @ epoch 6: **cat top-1 0.602, top-3 0.846, subcat top-1 0.5225**,
    cat macro-F1 0.251. Eval on 2k held-out Gemini-labeled val crops (own naming → valid join).
    Artifacts `$BUCKET/classifier/clip_v1/` + repo `classification/artifacts/clip_v1/`. **Beats the
    teammate's near-zero result** — confirms the 18/48-taxonomy thesis.
  - ✅ **Confidence gate TUNED (2026-06-28):** `infer.py --tune-threshold` sweep → clean monotonic
    curve. **Operating point 0.60: accept 51.5%, fallback 48.5%, acc@accept cat 78.5% / sub 70.1%.**
    New scripts `classification/tune_gate.sh` + `launch_tune_gate.sh`. Sweep in RESULTS.md.
- **NEXT (Module 2 wrap-up / scale-up options):**
  1. (optional) ResNet-50 fine-tune variant for the report's comparison row (`BACKBONE=resnet50
     VARIANT=resnet50_v1 bash classification/launch_train.sh`) — expected to beat frozen-CLIP.
  2. (optional) Scale labeling: label all 127k train crops + retrain, if 30k metrics warrant it.
  3. `infer.py` full-pipeline demo on a held-out shelf image (detect → classify → VLM fallback).
  4. Then Module 3 (Week 5): auto-labeling / FastAPI+SQLite backend.

### (archived) Week 3 — Module 1 detection
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
- **Cleanup-trap learning:** v8 + v11 both had `gcloud compute instances delete` return
  success but the VM stayed alive. Trap is now hardened with three layers (gcloud → REST
  API → scheduled `shutdown -h +5`) so this can't bleed cost in future runs.
- **Cloud NAT** in `us-central1` is now provisioned (router `nat-router-us-central1`,
  NAT `nat-config`, auto-allocated IPs, all subnet ranges) — required by the no-public-IP
  policy. Reused by every future VM in this project.

- **Detection next steps (deferred — Module 2 is active):**
  1. Run `notebooks/01_detection_checkpoint.ipynb` end-to-end (Colab, personal account).
  2. Copy v8/v11 `results.png` + the rendered before/after panels into `report/figures/`.
  3. Update `report/sections/06_results.tex` with both v8 and v11 numbers.

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

- **Detection v8** (YOLOv8m, time=9.5h, COCO init): mAP@0.5 = **0.9209**,
  mAP@0.5:0.95 = 0.5937, P = 0.9193, R = 0.8824, epoch 47/50.
- **Detection v11** (YOLOv11m, time=8.0h, COCO init): mAP@0.5 = **0.9209**,
  mAP@0.5:0.95 = **0.5941**, P = **0.9206**, R = 0.8815, epoch 35/50.
  Same accuracy, 1.5h less wall-clock. **First run with no-public-IP VM** (Cloud NAT egress).
- Artifacts: `gs://…/results/{v8,v11}/` and `detection/artifacts/{v8,v11}/` (committed in repo).
- Notebook samples: 10 real SKU-110K test images at `notebooks/samples/shelf_{00..09}.jpg`.

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
