"""Compare two label CSVs (or a label CSV against ground truth) — the DECISION GATE.

Two uses:

1. CLIP vs VLM agreement on the same crops (no ground truth needed):
     python -m autolabel.compare_labels --a labels_clip_val.csv --b labels_gemini_val.csv

   High agreement -> use the FREE CLIP labeler for the full set. Low agreement -> the labelers
   disagree, so trust the (stronger) VLM and budget for it.

2. A labeler vs GROUND TRUTH (the teammate's shared val CSV) — the honest quality measure:
     python -m autolabel.compare_labels --a labels_clip_val.csv \
         --b ~/Downloads/product_labels_openai_val_normalized_categories.csv --b-is-truth

Both inputs are joined on `filename`. Reports category and subcategory agreement %, the worst
confusions, and a per-category breakdown. Writes a markdown report (default
autolabel/label_agreement_report.md).
"""
from __future__ import annotations

import argparse
import csv
from collections import Counter, defaultdict
from pathlib import Path

CAT = "normalized_category"
SUB = "normalized_subcategory"


def load(path: str) -> dict[str, dict]:
    with open(path, newline="") as f:
        return {r["filename"]: r for r in csv.DictReader(f) if r.get("filename")}


def pct(num: int, den: int) -> str:
    return f"{(100.0 * num / den):.1f}%" if den else "n/a"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--a", required=True, help="First labels CSV (e.g. CLIP).")
    ap.add_argument("--b", required=True, help="Second labels CSV (e.g. VLM, or ground truth).")
    ap.add_argument("--b-is-truth", action="store_true", help="Treat --b as ground truth (changes wording).")
    ap.add_argument("--out", default="autolabel/label_agreement_report.md")
    ap.add_argument("--name-a", default="A")
    ap.add_argument("--name-b", default="B")
    args = ap.parse_args()

    A, B = load(args.a), load(args.b)
    common = sorted(set(A) & set(B))
    truth_word = "accuracy vs ground truth" if args.b_is_truth else "agreement"
    na, nb = args.name_a, args.name_b

    cat_match = sum(1 for fn in common if A[fn][CAT] == B[fn][CAT])
    sub_match = sum(1 for fn in common if A[fn][SUB] == B[fn][SUB])

    # Per-category breakdown (keyed on B's category — the reference/truth side).
    per_cat_total: Counter = Counter()
    per_cat_match: Counter = Counter()
    confusions: Counter = Counter()  # (b_cat -> a_cat) when they differ
    for fn in common:
        bc, ac = B[fn][CAT], A[fn][CAT]
        per_cat_total[bc] += 1
        if ac == bc:
            per_cat_match[bc] += 1
        else:
            confusions[(bc, ac)] += 1

    lines: list[str] = []
    lines.append(f"# Label {truth_word}: {na} vs {nb}\n")
    lines.append(f"- Files in {na}: {len(A)}  ·  in {nb}: {len(B)}  ·  joined on filename: {len(common)}\n")
    lines.append(f"- **Category {truth_word}: {pct(cat_match, len(common))}** ({cat_match}/{len(common)})")
    lines.append(f"- **Subcategory {truth_word}: {pct(sub_match, len(common))}** ({sub_match}/{len(common)})\n")

    lines.append(f"## Per-category {truth_word} (reference = {nb})\n")
    lines.append("| Category | N | match % |")
    lines.append("|---|---:|---:|")
    for cat in sorted(per_cat_total, key=lambda c: -per_cat_total[c]):
        lines.append(f"| {cat} | {per_cat_total[cat]} | {pct(per_cat_match[cat], per_cat_total[cat])} |")
    lines.append("")

    lines.append(f"## Top category confusions ({nb} → {na})\n")
    lines.append(f"| {nb} category | {na} predicted | count |")
    lines.append("|---|---|---:|")
    for (bc, ac), cnt in confusions.most_common(20):
        lines.append(f"| {bc} | {ac} | {cnt} |")
    lines.append("")

    # Decision hint.
    cat_pct = 100.0 * cat_match / len(common) if common else 0
    if not args.b_is_truth:
        verdict = (
            "High agreement → the FREE CLIP labeler is good enough; use it for the full set."
            if cat_pct >= 85
            else "Low agreement → trust the VLM labels and budget the VLM for the full set."
        )
        lines.append(f"## Decision\n\n{verdict} (category agreement = {cat_pct:.1f}%)\n")

    report = "\n".join(lines)
    Path(args.out).write_text(report)
    print(report)
    print(f"\n(written to {args.out})")


if __name__ == "__main__":
    main()
