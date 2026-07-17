# Retail Inventory AI

**Intelligent Retail Product Detection & Inventory Management System**
Computer Vision (YOLOv8 + ResNet-50 + CLIP + LLaVA) + LLM-based Business Intelligence.

An 8-week / 2-month project that automates product detection from shelf images, maintains a
live inventory database, and exposes a natural-language business-intelligence interface for
non-technical users. Full spec: `~/Downloads/Project_Proposal_Retail.pdf`.

---

## 🔄 How to "resume"

This project is built to be picked up across many sessions. To continue work:

1. Open this folder in Claude Code.
2. Say **"resume"**.
3. Claude reads [`PROJECT_MEMORY.md`](PROJECT_MEMORY.md) (the single source of truth for current
   status and next step) and continues from there. A persistent Claude memory also points back to
   this file so resume works even from a fresh context.

Every working session ends by updating `PROJECT_MEMORY.md` and appending to the running logs
(`DECISIONS.md`, `ISSUES.md`, `RESULTS.md`). **These logs are the raw material for the final
LaTeX report** — we assemble the report *from* them, not from memory.

---

## Project layout

| Path | Module | Week | Status |
|---|---|---|---|
| `detection/` | M1 — YOLOv8 detection (SKU-110K) | 3 | ✅ done (mAP@0.5≈0.92) |
| `classification/` | M2 — confidence-gated cat/subcat classifier (SKU-110K crops) | 4 | ✅ trained (see RESULTS.md) |
| `retrieval/` | M2b — SWIN + FAISS retrieval classifier (alternative to the trained classifier) | 4 | ✅ integrated + running |
| `autolabel/` | M2/M3 — CLIP + GCP VLM (Vertex Gemini / Gemma) labeling & fallback | 4–5 | 🚧 scaffolded |
| `backend/` | M4 — inventory store (SQLite) + (future) FastAPI | 5 | 🚧 SQLite store live |
| `bi_interface/` | M5 — natural-language BI (rule-based now, Ollama-ready) | 6 | 🚧 v1 live |
| `frontend/` | M7 — React/FastAPI operator UI, analytics + BI | 7 | 🚧 v2 live |
| `notebooks/` | Demo / checkpoint notebooks | — | 🚧 |
| `report/` | LaTeX final report | 8 | 🚧 skeleton |
| `docs/` | Diagrams, literature summaries | 1 | ⬜ |

Tracking files: `PROJECT_MEMORY.md` (resume), `DECISIONS.md`, `ISSUES.md`, `RESULTS.md`.

---

## Setup

Local Python is 3.14 (too new for the ML stack). Use a **Python 3.11** venv:

```bash
cd retail-inventory-ai
python3.11 -m venv .venv
source .venv/bin/activate

# Install only what you need per module, e.g. detection:
pip install -e ".[detection,dev]"
# or everything:
pip install -e ".[all]"

cp .env.example .env   # then fill in PROJECT_ID, BUCKET, etc.
```

> Heavy training runs on **GCP** (L4 GPU) or **Colab** — not the local macOS/CPU machine.

---

## 🚀 Run the ShelfSight retail assistant (Modules 2b / 4 / 5 / 7)

ShelfSight is an operator-first React application backed by FastAPI. Upload a shelf image and the
UI remains responsive while a single background inference worker runs YOLO detection, SWIN +
FAISS category matching, optional VLM SKU/OCR, and SQLite persistence. The result highlights
products that need review and keeps analytics, history, and natural-language inventory questions
in the same application.

```bash
cd retail-inventory-ai
python3.11 -m venv .venv
source .venv/bin/activate
pip install -e ".[retrieval,backend,dev]"
npm --prefix frontend/web install

# One-time: provision the SWIN/FAISS assets (~2.3 GB, gitignored).
# See retrieval/README.md for the exact copy commands from the teammate repo (Git LFS).

# Optional: enable real SKU/OCR extraction in the UI.
# Gemini works as the immediate Vertex reference backend (not open-source):
export PROJECT_ID=your-gcp-project
export REGION=us-central1
export VERTEX_MODEL=gemini-2.5-flash

# Open-source VLMs use the same UI once deployed behind an OpenAI-compatible endpoint:
# export VLM_ENDPOINT_URL=https://<qwen-or-paligemma-vllm-endpoint>/v1
# export VLM_API_KEY=<optional bearer token>

# Development: FastAPI on :8000 and Vite with hot reload on :5173.
bash frontend/run_web_dev.sh

# Production-style local build: FastAPI serves the compiled React app on :8000.
bash frontend/run_web_ui.sh
```

Primary destinations are **Scan Shelf**, **Insights**, **History**, and **Ask Inventory**. The
operator can expand **Analysis settings** to choose the number of products categorized, enable
SKU/package reading, and cap SKU crops. Model names, confidence thresholds, and endpoints remain
server-side configuration. Each result row also accepts separate category and SKU verdicts;
corrections are stored in SQLite for later evaluation or retraining. Insights include category
composition, subcategory breakdown, scan/empty-space trends, and human-feedback acceptance rates.
The legacy Streamlit and Gradio entrypoints
remain in `frontend/` temporarily but are no longer the production launch path.

### Serve ShelfSight from a GCP VM

For laptops with limited RAM, deploy the working tree and ignored model assets to a larger VM:

```bash
PROJECT_ID=your-gcp-project \
ZONE=us-central1-a \
INSTANCE=retail-inventory-ui-gpu \
bash frontend/deploy_hybrid_ui_gcp.sh
```

The script defaults to a `g2-standard-8` L4 GPU VM, serves one application on port `8000`, uploads
large ignored model assets once to a reusable GCS bucket, builds React locally, installs the
Python runtime, downloads assets from the bucket, and starts a `systemd` service. Access is IAP-only by default and
requires Cloud NAT for an address-less VM. If L4 capacity is unavailable, use the T4 fallback:

```bash
PROJECT_ID=your-gcp-project \
ZONE=us-central1-a \
INSTANCE=retail-inventory-ui-t4 \
MACHINE_TYPE=n1-standard-8 \
ACCELERATOR=type=nvidia-tesla-t4,count=1 \
SYNC_ASSETS_TO_GCS=0 \
bash frontend/deploy_hybrid_ui_gcp.sh
```

Open the IAP tunnel printed by the deployment:

```text
gcloud compute start-iap-tunnel <instance> 8000 --local-host-port=localhost:8000 ...
# then open http://localhost:8000
```

Stop the VM when the demo is done:

```bash
gcloud compute instances stop retail-inventory-ui-t4 --zone us-central1-a
```

SKU/OCR is enabled with `SKU_EXTRACT_DEFAULT=1` (the default). Set `SKU_BACKEND`, `SKU_MODEL`, and
the relevant Vertex or OpenAI-compatible endpoint environment variables on the service.
`MAX_CLASSIFICATION_CROPS` and `MAX_SKU_CROPS` provide server defaults; each scan can override
the two limits from **Analysis settings**.

The retrieval classifier reuses **our own** detector (`detection/artifacts/v11/best.pt`). Full
details + asset provisioning in [`retrieval/README.md`](retrieval/README.md).

---

## Today's deliverables (Week 3 — Detection checkpoint)

1. **Train YOLOv8m on SKU-110K** on a GCP L4 GPU VM (10h cap, auto-teardown, results → GCS).
   See [`detection/README.md`](detection/README.md).
2. **Before/after checkpoint notebook** — [`notebooks/01_detection_checkpoint.ipynb`](notebooks/01_detection_checkpoint.ipynb):
   YOLOv8m COCO weights *before* training vs our fine-tuned `best.pt` *after*, on the same shelf
   images. Upload to Colab and "Run all."

**Evaluation metrics captured:** mAP@0.5 and mAP@0.5:0.95 (targets: mAP@0.5 ≥ 0.70).
