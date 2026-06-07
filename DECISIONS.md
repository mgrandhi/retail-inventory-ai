# Decision Log (ADR-style)

Append-only. Newest at top. Each entry: **Date · Decision · Context · Rationale · Alternatives**.
This log feeds the "Design Decisions" section of the final report.

---

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
