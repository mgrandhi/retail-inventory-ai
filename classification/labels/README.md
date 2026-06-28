# Teacher labels (Module 2)

Gemini (`gemini-2.5-flash`) teacher labels for SKU-110K crops, used to train the two-head
classifier. Schema: `filename,normalized_category,normalized_subcategory,confidence,source`
against the fixed 18/48 taxonomy in `classification/taxonomy.py`.

| File | Rows | What |
|---|---|---|
| `labels_gemini_train.csv` | 30,000 | Train teacher labels — the classifier trains on these. |
| `labels_gemini_val.csv` | 2,000 | Held-out val labels — the classifier + confidence gate are evaluated on these. |

Filenames key off the **source shelf image's own number** (`val_102_det0_crop.jpg` ← `val_102.jpg`),
so the join to our crops is exact. These crops come from **our** YOLOv11 detector, so they do **not**
align 1:1 with a teammate's crops from a different detector — evaluate against *these* labels, not a
cross-detector CSV.

The rejected CLIP zero-shot labels (`labels_clip_val.csv`) are intentionally **not** committed — CLIP
was too weak on small crops (see `RESULTS.md` decision gate); they live in GCS only. Regenerate any
of these with `autolabel/launch_labels.sh`.
