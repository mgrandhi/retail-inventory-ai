# Decision Log (ADR-style)

Append-only. Newest at top. Each entry: **Date · Decision · Context · Rationale · Alternatives**.
This log feeds the "Design Decisions" section of the final report.

---

## 2026-07-08 · SKU database becomes product-master + inventory + checkout schema
- **Context:** The project needs to move from scan-level analytics to a database that supports
  product/SKU identity, inventory counts, automatic checkout, and model benchmark traceability.
  The existing SQLite store (`backend/inventory_db.py`) only held `scans` and `items`.
- **Decision:** Keep SQLite for the local demo, but define the logical schema as product-master
  tables (`products`, `product_aliases`), scan/detection tables (`shelf_scans`, `detected_items`),
  inventory tables (`inventory_snapshots`), checkout tables (`checkout_sessions`, `checkout_items`),
  and model-evaluation tables (`model_runs`, `model_predictions`).
- **Rationale:** Automatic checkout needs canonical products, prices, aliases, and review status;
  BI needs time-series inventory and checkout facts; model comparison needs run-level and per-crop
  prediction records. SQLite keeps the Streamlit demo simple while preserving a clean path to
  Postgres/Cloud SQL later.
- **Alternatives:** Keep only the current `scans/items` tables (rejected — insufficient for SKU
  resolution and checkout); jump directly to Cloud SQL (deferred — unnecessary for local/demo work).

## 2026-07-08 · Benchmark open VLMs for SKU/OCR before integrating product-name extraction
- **Context:** Category retrieval is working via SWIN+FAISS, but automatic checkout needs more
  precise SKU/product identity from crop images. The hard part is OCR on tiny/partial package text.
- **Decision:** Benchmark open multimodal models first: **Qwen2.5-VL-7B-Instruct / Qwen3-VL** as
  the primary OCR/KIE candidate, **PaliGemma 2 Mix** as the Google open VLM baseline, and
  **Gemma 3 multimodal** as the Google-native deployment baseline. Keep **Gemini 2.5 Flash** only
  as a non-open reference ceiling.
- **Rationale:** Qwen-VL has strong public OCR/key-information-extraction recipes; PaliGemma 2 Mix
  is Google’s open VLM family with OCR support through Model Garden; Gemma 3 is easiest to explain
  and deploy on Vertex but may be less OCR-specialized for packaging text. A benchmark prevents us
  from picking a model based on general VQA quality rather than SKU/OCR performance.
- **Alternatives:** Use Gemini directly for SKU extraction (rejected as the final model because it
  is not open-source); rely on SWIN+FAISS nearest-neighbour labels only (rejected for checkout
  because category/subcategory is not enough to identify sellable SKUs).

## 2026-06-27 · Classifier targets the normalized taxonomy (18/48), not product names
- **Context:** Mentor reframed Module 2: train a classifier, gate on its confidence, fall back to
  an LLM only for low-confidence crops. A teammate's classifier on the shared SKU crops scored
  "very low."
- **Decision:** The trainable classifier predicts **normalized_category (18) + normalized_subcategory
  (48)** as two heads. The fine-grained product name is NOT a classifier target — it's produced by
  the VLM fallback only.
- **Rationale:** The shared val labels have **9,685 unique `product_label` values across 15,000
  crops** (~1.5 examples/class) — impossible to classify, which explains the near-zero accuracy.
  The normalized columns collapse to 18/48 classes with hundreds of examples each — learnable. The
  taxonomy is a clean tree (every subcat → exactly one cat), so we mask the subcat head to the
  chosen category for consistency.
- **Alternatives:** Classify product_label directly (rejected — unlearnable with current data);
  category-only single head (rejected — loses subcategory granularity the BI layer wants).

## 2026-06-27 · Auto-labeling + LLM fallback use GCP Vertex (Gemini/Gemma), not OpenAI
- **Context:** Need labels for the unlabeled SKU crops, and a low-confidence fallback model.
  Teammate used OpenAI gpt-5.4-mini; user wants everything inside the GCP project.
- **Decision:** Use **Vertex AI Gemini** (default `gemini-2.5-flash` — verified callable 2026-06-27; gemini-3.x was NOT available in-project, via the `google-genai` SDK
  with `vertexai=True`) as the default labeler + fallback, with a **self-hosted Gemma 3** (Ollama)
  backend as the $0-per-call alternative. Auth = VM service account (`roles/aiplatform.user`); no
  API key. `autolabel/label_vlm.py` is backend-agnostic (`--backend gemini|gemma`).
- **Rationale:** Keeps all compute + spend in one cloud account, no external API egress, reuses the
  no-public-IP + Cloud NAT pattern. Output is constrained to the taxonomy via a JSON-schema enum.
- **Alternatives:** OpenAI (rejected — out-of-project cost/egress); CLIP-only (kept as the free
  labeler and compared against Gemini via `compare_labels.py` — the decision gate for the full set).

## 2026-06-27 · Generate crops from SKU-110K with our detector; 10% of train first
- **Context:** Module 2 needs per-product crops, but SKU-110K ships as full shelf images. We have
  a mAP@0.5≈0.92 detector (`detection/artifacts/v11/best.pt`).
- **Decision:** Crop SKU-110K ourselves with `best.pt` (`gen_crops.py`), naming crops to match the
  teammate's val export so the shared val CSV joins by filename. Start at **`--fraction 0.10`** of
  train (all val/test), evaluate, then scale.
- **Rationale:** Owns the full pipeline end-to-end (no dependency on the teammate's crop files);
  10%-first bounds crop + labeling cost until the pipeline is proven. Inference-only, so it runs on
  a cheap GPU/CPU VM that self-deletes.

## 2026-06-06 · Colab notebook does inference only; GCP does the real training
- **Context:** Today's checkpoint deliverable is a Colab notebook showing before/after detection.
  Colab free tier disconnects after a few hours, too short for a full 50-epoch run at 1280.
- **Decision:** The GCP L4 VM runs the real 50-epoch training and writes `best.pt` + `metrics.json`
  to GCS. The Colab notebook downloads `best.pt` and only runs **inference** (before/after panels).
- **Rationale:** Honest, full-quality metrics from GCP; fast, shareable, disconnect-proof demo in
  Colab. Metrics reported in the notebook are the real ones, not a truncated proxy.
- **Alternatives:** Colab-native full training (rejected — session limits); Colab Pro (rejected —
  unnecessary subscription cost when GCP run is already planned).

## 2026-06-06 · GPU = 1× NVIDIA L4 (not T4 or P4)
- **Context:** Need YOLOv8m fine-tuned on SKU-110K within ~10 hours on GCP. User asked about T4
  (with 26 GB), then P4, then multi-GPU T4.
- **Decision:** Use a single **NVIDIA L4** on `g2-standard-8`.
- **Rationale:** Under a fixed time budget, more GPU throughput = more epochs / higher mAP for
  ~the same total bill. L4 (Ada, 24 GB VRAM) is ~2–3× a T4 and single-GPU (no DDP). It beats
  2×T4 on both speed and simplicity. The "26 GB" in the original ask was **system RAM**, not VRAM
  (a T4 has 16 GB VRAM); `g2-standard-8` provides 32 GB RAM.
- **Alternatives:** T4 ×1 (cheapest/hr but fewest epochs in 10h); 2×T4 (kept as no-quota fallback,
  DDP `device=0,1`, ~$1.18/hr); **P4 rejected** (Pascal, no tensor cores, 8 GB — a downgrade at 1280).

## 2026-06-06 · Bound wall-clock with Ultralytics `time=`, not fixed epochs
- **Context:** User wants results by end of day (~10h budget). A single GPU can't guarantee a fixed
  epoch count finishes in a fixed time at imgsz=1280.
- **Decision:** Train with `time=9.5` (hard 9.5h cap; auto-scales/auto-stops epochs) and
  `epochs=50` only as an upper bound, leaving ~30 min for final val + GCS sync.
- **Rationale:** Guarantees a bounded run and bounded cost regardless of GPU speed.

## 2026-06-06 · VM auto-deletes after syncing results to GCS
- **Context:** Cost control — avoid paying for an idle GPU VM after training.
- **Decision:** Startup script syncs all artifacts to GCS then self-deletes the instance.
  `teardown.sh` is a manual safety net.
- **Rationale:** ~$8–9 bounded cost; nothing of value lives only on the VM disk.

## 2026-06-06 · Dataset via Ultralytics built-in `SKU-110K.yaml` (no Kaggle)
- **Context:** No Kaggle CLI/credentials on the local machine.
- **Decision:** Use Ultralytics' built-in `SKU-110K.yaml`, which auto-downloads + converts the
  dataset (~13.6 GB) on the VM at first use.
- **Rationale:** Avoids the Kaggle credential path entirely; reproducible and self-contained.
