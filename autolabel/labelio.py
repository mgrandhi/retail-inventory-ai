"""Shared label-output schema + resumable-CSV helpers for the autolabelers.

Both labelers (CLIP and the GCP VLM) emit the SAME columns so compare_labels.py and the
classifier can consume either interchangeably. The schema is a superset of the teammate's
val CSV (`filename, normalized_category, normalized_subcategory`) plus a confidence and a
provenance column.
"""
from __future__ import annotations

import csv
from pathlib import Path

# The canonical output columns every labeler writes.
FIELDS = [
    "filename",               # crop file name (joins to crops_manifest.csv + the val CSV)
    "normalized_category",    # one of the 18 taxonomy categories
    "normalized_subcategory", # one of the 48 taxonomy subcategories
    "confidence",             # [0,1] — CLIP softmax max, or VLM self-reported / 1.0
    "source",                 # "clip" | "gemini" | "gemma" | "openai" — provenance
]


def already_labeled(out_csv: str | Path) -> set[str]:
    """Return the set of filenames already present in `out_csv` (for resumable runs)."""
    p = Path(out_csv)
    if not p.exists():
        return set()
    with open(p, newline="") as f:
        return {row["filename"] for row in csv.DictReader(f) if row.get("filename")}


def open_writer(out_csv: str | Path):
    """Open `out_csv` for appending label rows, writing the header if the file is new.

    Returns (file_handle, dict_writer). Caller is responsible for closing the handle.
    """
    p = Path(out_csv)
    p.parent.mkdir(parents=True, exist_ok=True)
    is_new = not p.exists() or p.stat().st_size == 0
    f = open(p, "a", newline="")
    w = csv.DictWriter(f, fieldnames=FIELDS)
    if is_new:
        w.writeheader()
        f.flush()
    return f, w
