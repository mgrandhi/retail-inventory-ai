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

## Classification (Module 2 — confidence-gated cat/subcat + VLM fallback) — Week 4

**Design pivot (2026-06-27):** classifier targets the **normalized taxonomy (18 categories /
48 subcategories)**, NOT the ~9,685 `product_label` values (~1.5 ex each → why the first attempt
scored near-zero). Confidence-gated: classifier handles high-confidence crops, GCP VLM
(Vertex Gemini / self-hosted Gemma) handles low-confidence ones. Crops generated from SKU-110K
with the v11 detector. 10%-first, then scale.

### Label quality — decision gate (2026-06-27)
**Labeler chosen: Vertex Gemini (gemini-2.5-flash).** CLIP zero-shot is too weak on small/partial
SKU crops.

- **CLIP vs Gemini agreement** (2,000 val crops both labeled): **category 24.2%**, subcategory 18.4%
  — large disagreement (`autolabel/cmp_clip_vs_gemini.md`). CLIP misfires systematically to
  "Tobacco / Restricted" and "Oral Care", or bails to "Unclear".
- **Visual spot-check** (crops pulled + eyeballed) settles who's right on disagreements: on 4
  inspected, Gemini correct 4/4, CLIP 1/4:
  | Crop | Eyeball truth | CLIP | Gemini |
  |---|---|---|---|
  | Lemsip Cold&Flu | Medicine | Tobacco ✗ | Medicine & First Aid ✓ |
  | KIND bar | Snack | Unclear ✗ | Snack Bars ✓ |
  | Method spray | Cleaner | Unmapped ✗ | Household Cleaners ✓ |
  | Sainsbury's maxi towels | Feminine Hygiene | Feminine Hygiene ✓ | Feminine Hygiene ✓ |
- **Gemini cost (measured):** 2,000 crops, 0 errors, ~1.85M tokens, 221 s, 9.1 crops/s (8 workers,
  T4 VM). ~925 tok/crop (image tokens scale with crop resolution). Projects to ≈ $1–3 for the
  10% train labeling, well within budget.

> ⚠️ **Per-crop accuracy vs the teammate's shared val CSV is NOT reported** — it is not a valid
> join. Their crops come from a *different detector* (≈199 boxes/image vs our ≈157) and our crop
> filenames were initially built from a 0-based loop counter, so `val_102_det0` referred to
> different physical crops in each set. Naming is now fixed in `gen_crops.py` (key off the source
> image's own number, e.g. `val_102.jpg → val_102_detN`), but box ordering still won't align
> across detectors — so the honest label-quality signal is the visual spot-check above, and the
> real downstream metric is **classifier accuracy on a held-out split of our OWN Gemini-labeled
> crops** (next).

### Classifier
| Date | Backbone | Train crops | Cat top-1 | Cat top-3 | Subcat top-1 | Cat macro-F1 | Notes |
|---|---|---|---|---|---|---|---|
| 2026-06-28 | CLIP-frozen + 2 heads | 30k Gemini-labeled | **0.602** | **0.846** | **0.5225** | 0.2512 | baseline; best @ epoch 6/15; eval on 2k held-out Gemini-labeled val crops (own naming, valid join). Frozen backbone → linear-probe ceiling. Artifacts `gs://…/classifier/clip_v1/`. Macro-F1 low: dragged by rare classes (Electronics=4, Pet Care=14 train ex.) + the dominant 44% "Other/Unclear" bucket. |
| _pending_ | ResNet-50 fine-tune | 30k Gemini-labeled | — | — | — | — | proposal's literal model; expected to beat frozen-CLIP via end-to-end fine-tune |

**Teacher labels (Gemini, train):** 30,000 crops, **0 errors**, 27.9M tokens, 779 s, **38.5 crops/s**
(32 workers, e2-standard-8 CPU VM). Category mix: 44% "Other/Unclear" (tiny/partial/back-of-pack
SKU-110K crops with no identifiable branding — exactly what the confidence gate should route to the
VLM), 56% across 17 real categories (Personal Care 17%, Beverages 11%, Health 8%, …).

> **Beats the teammate's near-zero classifier result decisively** — confirms the plan's core thesis:
> the normalized 18/48 taxonomy is learnable where the 9,685 `product_label` values (~1.5 ex each)
> were not.

### Confidence gate (val)
Swept `infer.py --tune-threshold` on the 2,000 held-out Gemini-labeled val crops (clip_v1). The
curve is **monotonic and well-calibrated** — raising the gate trades coverage for accuracy cleanly,
which is exactly what the confidence-gated design needs. `overall_cat` = upper bound assuming a
perfect VLM on the fallback set.

| Threshold | Accept rate | Fallback rate | Acc@accepted (cat) | Acc@accepted (subcat) | Overall cat (ub) |
|---|---|---|---|---|---|
| 0.30 | 93.0% | 7.0% | 0.629 | 0.548 | 0.655 |
| 0.40 | 78.5% | 21.4% | 0.682 | 0.597 | 0.751 |
| 0.50 | 64.0% | 36.0% | 0.740 | 0.650 | 0.834 |
| **0.60** ⭐ | **51.5%** | **48.5%** | **0.785** | **0.701** | **0.890** |
| 0.70 | 39.2% | 60.8% | 0.847 | 0.765 | 0.940 |
| 0.80 | 28.3% | 71.7% | 0.905 | 0.827 | 0.973 |
| 0.90 | 15.8% | 84.2% | 0.946 | 0.899 | 0.992 |

**Recommended operating point: threshold 0.60** — the classifier confidently handles ~half the
crops at **78.5% category / 70.1% subcategory accuracy** (vs 60.2%/52.3% ungated), and routes the
hard half to the Gemini VLM fallback. Push to 0.70 for ~85% accuracy on the accepted third if
fallback budget allows; drop to 0.50 to accept ~two-thirds at ~74%. `gate_sweep.json` +
`gate.log` in `gs://…/classifier/clip_v1/`.

## Auto-labeling (Module 3 — LLaVA) — Week 5
_not started_

## NL BI interface (Module 5) — Week 6
_not started_

## System-level — Week 7+
_not started_
