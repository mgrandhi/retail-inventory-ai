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
| `classification/` | M2 — confidence-gated cat/subcat classifier (SKU-110K crops) | 4 | 🚧 scaffolded |
| `autolabel/` | M2/M3 — CLIP + GCP VLM (Vertex Gemini / Gemma) labeling & fallback | 4–5 | 🚧 scaffolded |
| `backend/` | M4 — FastAPI + SQLite | 5 | ⬜ not started |
| `bi_interface/` | M5 — LangGraph + Ollama NL→SQL | 6 | ⬜ not started |
| `frontend/` | M7 — Streamlit dashboard | 7 | ⬜ not started |
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
> Streamlit (once Module 7 exists): `streamlit run frontend/app.py`.

---

## Today's deliverables (Week 3 — Detection checkpoint)

1. **Train YOLOv8m on SKU-110K** on a GCP L4 GPU VM (10h cap, auto-teardown, results → GCS).
   See [`detection/README.md`](detection/README.md).
2. **Before/after checkpoint notebook** — [`notebooks/01_detection_checkpoint.ipynb`](notebooks/01_detection_checkpoint.ipynb):
   YOLOv8m COCO weights *before* training vs our fine-tuned `best.pt` *after*, on the same shelf
   images. Upload to Colab and "Run all."

**Evaluation metrics captured:** mAP@0.5 and mAP@0.5:0.95 (targets: mAP@0.5 ≥ 0.70).
