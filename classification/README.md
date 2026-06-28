# Module 2 — Classification (confidence-gated)

Per-product **category + subcategory** classification of crops from shelf images, with an
**LLM fallback** for the crops the classifier is unsure about. This is the mentor's design:

```
shelf image ──YOLO(best.pt)──▶ crops ──▶ classifier(crop) ─▶ (cat, subcat, confidence)
                                              │
                                  confidence ≥ threshold ? ──yes──▶ use classifier label  (cheap)
                                              │
                                              └────────────no────▶ GCP VLM fallback        (only hard crops)
```

## Why category/subcategory and not product name

The shared OpenAI labels (`~/Downloads/product_labels_openai_val_normalized_categories.csv`,
15,000 crops) have **~9,685 unique `product_label` values** — about 1.5 examples per product.
No classifier can learn that; this is why the first attempt scored near-zero. The *normalized*
columns collapse to a learnable space:

| Target | Classes | Trainable |
|---|---|---|
| product_label | 9,685 | ❌ (~1 example each) |
| **normalized_category** | **18** | ✅ |
| **normalized_subcategory** | **48** | ✅ |

So the **classifier predicts the 18/48 normalized taxonomy**; the fine-grained product name is
left to the **VLM fallback** only. The taxonomy is the single source of truth in
`classification/taxonomy.py` (+ `taxonomy.json`); every component imports its label space from it.

## Everything runs in GCP (no OpenAI)

The LLM labeler and the fallback use a **GCP-hosted VLM** — **Vertex AI Gemini** (default
`gemini-2.5-flash`, set via `$VERTEX_MODEL`) or **self-hosted Gemma 3** via Ollama. Auth on the
VM is the service account (grant `roles/aiplatform.user`) — **no API key**. VMs follow the same
policy as detection: **no public IP**, Cloud NAT egress, IAP for SSH, 3-layer self-delete trap.

> ⚠️ Vertex is now branded "Gemini Enterprise Agent Platform" and model ids version fast.
> Verify the exact `$VERTEX_MODEL` id against the live Model Garden before a big labeling run.

## Run order (10%-first)

```bash
source .env   # PROJECT_ID, REGION, BUCKET, DATASETS_BUCKET, VERTEX_MODEL

# 0. (one-time) regenerate the taxonomy if the label space changes
python -m classification.taxonomy --from-csv ~/Downloads/product_labels_openai_val_normalized_categories.csv

# 1. Generate crops from SKU-110K (10% of train, all val/test). Self-deleting GCP VM.
bash classification/launch_crops.sh
gsutil -m cp -r $BUCKET/crops ./data/crops          # pull when the VM disappears

# 2. Label the crops:
python -m autolabel.label_clip --crops data/crops/val --out autolabel/labels_clip_val.csv         # FREE
python -m autolabel.label_vlm  --backend gemini --crops data/crops/val --out autolabel/labels_gemini_val.csv --workers 8

# 3. DECISION GATE — compare, and validate against the shared ground truth:
python -m autolabel.compare_labels --a autolabel/labels_clip_val.csv --b autolabel/labels_gemini_val.csv \
    --name-a CLIP --name-b Gemini
python -m autolabel.compare_labels --a autolabel/labels_clip_val.csv \
    --b ~/Downloads/product_labels_openai_val_normalized_categories.csv --b-is-truth --name-a CLIP --name-b OpenAI
# -> autolabel/label_agreement_report.md decides CLIP (free) vs VLM for the full train set.

# 4. Label the train crops with the chosen labeler, then train (self-deleting L4 VM):
#    (stage train labels + val ground truth in GCS first)
export TRAIN_LABELS=gs://.../labels_train.csv VAL_LABELS=gs://.../product_labels_openai_val_normalized_categories.csv
export BACKBONE=clip VARIANT=clip_v1
bash classification/launch_train.sh
gsutil cat $BUCKET/classifier/clip_v1/metrics.json   # cat/sub top-1, top-3, macro-F1

# 5. Pick the confidence threshold, then run the gated pipeline:
python -m classification.infer --tune-threshold --model-dir classification/artifacts/clip_v1 \
    --crops data/crops/val --truth ~/Downloads/product_labels_openai_val_normalized_categories.csv
python -m classification.infer --model-dir classification/artifacts/clip_v1 \
    --crops data/crops/test --out classification/preds_test.csv --threshold 0.6 --backend gemini
```

## Scaling past 10%

If the 10% metrics look good, bump `FRACTION` and rerun steps 1–4:
`FRACTION=0.5 bash classification/launch_crops.sh`, etc. Log every run in `RESULTS.md`.

## Files

| File | Role |
|---|---|
| `taxonomy.py` / `taxonomy.json` | the fixed 18/48 label space (single source of truth) |
| `gen_crops.py` + `crop_sku110k.sh` + `launch_crops.sh` | detect → crop SKU-110K, upload to GCS |
| `../autolabel/label_clip.py` | free zero-shot CLIP labeler |
| `../autolabel/label_vlm.py` | GCP VLM labeler (`--backend gemini\|gemma`) |
| `../autolabel/compare_labels.py` | CLIP-vs-VLM-vs-truth agreement → decision gate |
| `classifier_lib.py` | two-head model + dataset (shared by train + infer) |
| `train_classifier.py` + `train_classifier.sh` + `launch_train.sh` | train the classifier on GCP |
| `infer.py` | confidence-gated inference + threshold tuning |

CPU smoke test: every script runs locally on the 10% subset (slow but fine) once
`pip install -e ".[classification,autolabel]"` is done in a Python 3.11 venv.
