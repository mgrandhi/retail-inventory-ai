"""Shared normalized taxonomy for Module 2 (classification).

This is the SINGLE SOURCE OF TRUTH for the label space. The CLIP labeler, the GCP VLM
labeler, and the two-head classifier all import their category/subcategory lists from here
so they can never drift to different label strings.

Why a fixed taxonomy at all? The teammate's OpenAI labels have ~9,685 unique *product*
names across 15,000 crops (~1.5 examples each) — impossible to classify. But the
*normalized* columns collapse to 18 categories and 48 subcategories, each with plenty of
examples. The trainable classifier targets these; the fine-grained product name is left to
the LLM fallback only. See classification/README.md.

The canonical taxonomy lives in `taxonomy.json` next to this file. Regenerate it from a
labels CSV with:

    python -m classification.taxonomy --from-csv ~/Downloads/product_labels_openai_val_normalized_categories.csv

Inspect the loaded taxonomy with:

    python -m classification.taxonomy --show
"""
from __future__ import annotations

import argparse
import csv
import json
from collections import Counter, defaultdict
from functools import lru_cache
from pathlib import Path

TAXONOMY_JSON = Path(__file__).with_name("taxonomy.json")

# CSV column names (the schema the teammate's OpenAI export uses, and the schema our
# labelers emit). Kept here so every module references the same strings.
COL_CATEGORY = "normalized_category"
COL_SUBCATEGORY = "normalized_subcategory"


class Taxonomy:
    """Loaded normalized taxonomy with the lookup helpers the rest of the module needs."""

    def __init__(self, categories: dict[str, list[str]]):
        # categories: {category -> [subcategory, ...]} (the parent->children map)
        self.categories: dict[str, list[str]] = {c: list(subs) for c, subs in categories.items()}

        # Stable, sorted index lists — these define the integer class ids used by the
        # classifier heads. Sorted so the ids are deterministic across machines/runs.
        self.category_names: list[str] = sorted(self.categories)
        self.subcategory_names: list[str] = sorted(
            {s for subs in self.categories.values() for s in subs}
        )

        self.cat_to_id: dict[str, int] = {c: i for i, c in enumerate(self.category_names)}
        self.sub_to_id: dict[str, int] = {s: i for i, s in enumerate(self.subcategory_names)}

        # subcategory -> parent category (each subcat belongs to exactly one category).
        self.sub_to_cat: dict[str, str] = {}
        for cat, subs in self.categories.items():
            for s in subs:
                self.sub_to_cat[s] = cat

    # --- sizes -------------------------------------------------------------
    @property
    def n_categories(self) -> int:
        return len(self.category_names)

    @property
    def n_subcategories(self) -> int:
        return len(self.subcategory_names)

    # --- membership / validation ------------------------------------------
    def is_category(self, name: str) -> bool:
        return name in self.cat_to_id

    def is_subcategory(self, name: str) -> bool:
        return name in self.sub_to_id

    def parent_of(self, subcategory: str) -> str:
        return self.sub_to_cat[subcategory]

    def subcategories_of(self, category: str) -> list[str]:
        return self.categories[category]

    def subcategory_ids_of(self, category: str) -> list[int]:
        """Integer ids of the subcategories valid under `category` — used to MASK the
        subcategory head so it can only predict children of the chosen category."""
        return [self.sub_to_id[s] for s in self.categories[category]]

    # --- prompt text for zero-shot CLIP -----------------------------------
    def category_prompts(self, template: str = "a retail product, category: {}") -> list[str]:
        return [template.format(c) for c in self.category_names]

    def subcategory_prompts(self, template: str = "a retail product, type: {}") -> list[str]:
        return [template.format(s) for s in self.subcategory_names]


@lru_cache(maxsize=1)
def load(path: str | Path = TAXONOMY_JSON) -> Taxonomy:
    """Load the canonical taxonomy (cached)."""
    data = json.loads(Path(path).read_text())
    return Taxonomy(data["categories"])


def build_from_csv(csv_path: str | Path) -> dict:
    """Derive the taxonomy dict from a labels CSV (the regeneration path).

    Validates the core invariant that every subcategory maps to exactly one category.
    """
    rows = list(csv.DictReader(open(csv_path)))
    cat_to_subs: dict[str, set[str]] = defaultdict(set)
    sub_to_cats: dict[str, set[str]] = defaultdict(set)
    cat_counts: Counter = Counter()
    sub_counts: Counter = Counter()
    for r in rows:
        cat = r[COL_CATEGORY]
        sub = r[COL_SUBCATEGORY]
        cat_to_subs[cat].add(sub)
        sub_to_cats[sub].add(cat)
        cat_counts[cat] += 1
        sub_counts[sub] += 1

    ambiguous = {s: sorted(cs) for s, cs in sub_to_cats.items() if len(cs) > 1}
    if ambiguous:
        raise ValueError(
            "Taxonomy is not a clean tree — these subcategories map to >1 category:\n"
            + json.dumps(ambiguous, indent=2)
        )

    categories = {cat: sorted(cat_to_subs[cat]) for cat in sorted(cat_to_subs)}
    return {
        "_meta": {
            "source": Path(csv_path).name,
            "n_rows": len(rows),
            "n_categories": len(categories),
            "n_subcategories": sum(len(v) for v in categories.values()),
            "note": (
                "Canonical normalized taxonomy for Module 2 classification. "
                "Regenerate with: python -m classification.taxonomy --from-csv <val.csv>"
            ),
        },
        "categories": categories,
        "category_counts": dict(cat_counts.most_common()),
        "subcategory_counts": dict(sub_counts.most_common()),
    }


def _main() -> None:
    ap = argparse.ArgumentParser(description="Build or inspect the normalized taxonomy.")
    ap.add_argument("--from-csv", help="Regenerate taxonomy.json from this labels CSV.")
    ap.add_argument("--out", default=str(TAXONOMY_JSON), help="Where to write the JSON.")
    ap.add_argument("--show", action="store_true", help="Print the currently loaded taxonomy.")
    args = ap.parse_args()

    if args.from_csv:
        data = build_from_csv(args.from_csv)
        Path(args.out).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        m = data["_meta"]
        print(
            f"Wrote {args.out}: {m['n_categories']} categories, "
            f"{m['n_subcategories']} subcategories from {m['n_rows']} rows."
        )
        return

    tax = load()
    print(f"{tax.n_categories} categories, {tax.n_subcategories} subcategories\n")
    if args.show:
        for cat in tax.category_names:
            print(f"  {cat}")
            for sub in tax.subcategories_of(cat):
                print(f"      - {sub}")


if __name__ == "__main__":
    _main()
