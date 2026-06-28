"""GCP VLM crop labeler — labels product crops with a Google-hosted vision model.

NO OpenAI, NO external API: everything runs inside the GCP project.

Two pluggable backends:
  --backend gemini  -> Vertex AI via the google-genai SDK (client(vertexai=True, project, location)).
                       Auth is the environment's service account (roles/aiplatform.user) — NO API key.
                       Model id from $VERTEX_MODEL (default gemini-2.5-flash; gemini-2.5-flash-lite
                       is the cheaper alternative — both verified callable in this project
                       2026-06-27). VERIFY the exact id against the live Model Garden before a big
                       run — ids version fast (gemini-3.x was NOT available here).
  --backend gemma   -> self-hosted Gemma 3 vision via Ollama on the same GPU VM ($0 per call).

The model is asked to choose a `normalized_subcategory` from the 48-value enum of the fixed
taxonomy (classification/taxonomy.py). Because the taxonomy is a clean tree, we DERIVE the
`normalized_category` from the chosen subcategory — this guarantees the two are always
consistent and constrains the model to our exact label strings. Output schema = labelio.py.

Resumable (skips filenames already in --out) and multi-worker (--workers N). A token/latency
log is written next to the CSV so we can project full-set cost from the 10% subset.

Usage:
  export PROJECT_ID=... REGION=us-central1 VERTEX_MODEL=gemini-2.5-flash
  python -m autolabel.label_vlm --backend gemini --crops data/crops/val \
      --out autolabel/labels_gemini_val.csv --workers 8
"""
from __future__ import annotations

import argparse
import json
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from classification import taxonomy
from autolabel import labelio

IMG_EXTS = {".jpg", ".jpeg", ".png", ".bmp"}

PROMPT = (
    "You are labeling a single cropped retail product image from a store shelf. "
    "Choose the ONE normalized_subcategory from the allowed list that best fits the product. "
    "If the crop is unclear, blurry, or not a recognizable product, choose "
    "'Unclear / Generic Product'. Also give the specific product_label (brand + product, e.g. "
    "'Coca-Cola Can') if you can read/recognize it, else an empty string. "
    "Respond with JSON only."
)


def iter_crops(crops_dir: Path):
    for p in sorted(crops_dir.rglob("*")):
        if p.suffix.lower() in IMG_EXTS:
            yield p


def mime_for(path: Path) -> str:
    return "image/png" if path.suffix.lower() == ".png" else "image/jpeg"


# --------------------------------------------------------------------------
# Backends. Each exposes label_one(path) -> (subcategory, product_label, raw_usage_tokens).
# --------------------------------------------------------------------------
class GeminiBackend:
    def __init__(self, model: str, project: str, location: str, subcategories: list[str]):
        from google import genai
        from google.genai import types

        self._types = types
        self.model = model
        self.client = genai.Client(vertexai=True, project=project, location=location)
        # Constrain output to our exact label strings via a JSON schema with an enum.
        self.schema = {
            "type": "object",
            "properties": {
                "normalized_subcategory": {"type": "string", "enum": subcategories},
                "product_label": {"type": "string"},
            },
            "required": ["normalized_subcategory"],
        }

    def label_one(self, path: Path):
        types = self._types
        data = path.read_bytes()
        resp = self.client.models.generate_content(
            model=self.model,
            contents=[PROMPT, types.Part.from_bytes(data=data, mime_type=mime_for(path))],
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                response_json_schema=self.schema,
                temperature=0.0,
                # Single-label classification needs no chain-of-thought. Disabling thinking on
                # gemini-2.5-flash drops ~136 billable "thoughts" tokens/crop (~34% of spend) with
                # no accuracy loss on this task (verified 2026-06-27). Harmless on non-2.5 models.
                thinking_config=types.ThinkingConfig(thinking_budget=0),
            ),
        )
        obj = json.loads(resp.text)
        tokens = 0
        usage = getattr(resp, "usage_metadata", None)
        if usage is not None:
            tokens = int(getattr(usage, "total_token_count", 0) or 0)
        return obj.get("normalized_subcategory", ""), obj.get("product_label", ""), tokens


class GemmaBackend:
    """Self-hosted Gemma 3 vision via Ollama (running on the same VM). Zero per-call cost."""

    def __init__(self, model: str, subcategories: list[str], host: str | None = None):
        import ollama

        self.model = model  # e.g. "gemma3:12b"
        self.client = ollama.Client(host=host) if host else ollama.Client()
        self.subcategories = subcategories
        self._enum_text = ", ".join(subcategories)

    def label_one(self, path: Path):
        prompt = (
            PROMPT
            + "\nThe normalized_subcategory MUST be exactly one of: "
            + self._enum_text
            + '\nReturn JSON: {"normalized_subcategory": "...", "product_label": "..."}'
        )
        resp = self.client.generate(
            model=self.model,
            prompt=prompt,
            images=[str(path)],
            format="json",
            options={"temperature": 0.0},
        )
        obj = json.loads(resp["response"])
        return obj.get("normalized_subcategory", ""), obj.get("product_label", ""), 0


def build_backend(args, subcategories):
    if args.backend == "gemini":
        project = os.environ.get("PROJECT_ID") or args.project
        location = os.environ.get("REGION") or args.location
        model = os.environ.get("VERTEX_MODEL") or args.model or "gemini-2.5-flash"
        if not project:
            raise SystemExit("gemini backend needs PROJECT_ID (env or --project).")
        print(f"backend=gemini model={model} project={project} location={location}")
        return GeminiBackend(model, project, location, subcategories)
    elif args.backend == "gemma":
        model = args.model or os.environ.get("GEMMA_MODEL") or "gemma3:12b"
        print(f"backend=gemma model={model}")
        return GemmaBackend(model, subcategories, host=os.environ.get("OLLAMA_HOST"))
    raise SystemExit(f"unknown backend {args.backend}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backend", required=True, choices=["gemini", "gemma"])
    ap.add_argument("--crops", required=True, help="Directory of crop images (recursed).")
    ap.add_argument("--out", required=True, help="Output labels CSV (resumable — appends).")
    ap.add_argument("--workers", type=int, default=8, help="Concurrent requests.")
    ap.add_argument("--limit", type=int, default=0, help="Label at most N crops (0 = all). For cost-bounded sampling.")
    ap.add_argument("--model", default=None, help="Override model id (else env/default).")
    ap.add_argument("--project", default=None, help="GCP project (gemini; else $PROJECT_ID).")
    ap.add_argument("--location", default="us-central1", help="Vertex location (gemini; else $REGION).")
    args = ap.parse_args()

    tax = taxonomy.load()
    backend = build_backend(args, tax.subcategory_names)

    done = labelio.already_labeled(args.out)
    crops = [p for p in iter_crops(Path(args.crops)) if p.name not in done]
    if args.limit:
        crops = crops[: args.limit]
    print(f"{len(crops)} crops to label ({len(done)} already done)")

    f, writer = labelio.open_writer(args.out)
    lock = threading.Lock()
    stats = {"n": 0, "tokens": 0, "errors": 0}
    t0 = time.time()

    def work(path: Path):
        try:
            sub, product, tokens = backend.label_one(path)
            # Coerce to a valid taxonomy subcategory; derive the parent category.
            if not tax.is_subcategory(sub):
                sub = "Unclear / Generic Product"
            cat = tax.parent_of(sub)
            return path.name, cat, sub, tokens, None
        except Exception as e:  # one bad crop must not kill the batch
            return path.name, None, None, 0, str(e)

    try:
        with ThreadPoolExecutor(max_workers=args.workers) as ex:
            futures = [ex.submit(work, p) for p in crops]
            for fut in as_completed(futures):
                name, cat, sub, tokens, err = fut.result()
                with lock:
                    if err:
                        stats["errors"] += 1
                        if stats["errors"] <= 10:
                            print(f"WARN: {name}: {err}")
                        continue
                    writer.writerow({
                        "filename": name,
                        "normalized_category": cat,
                        "normalized_subcategory": sub,
                        "confidence": 1.0,  # VLM doesn't return calibrated probs; treated as "labeler ground truth"
                        "source": args.backend,
                    })
                    stats["n"] += 1
                    stats["tokens"] += tokens
                    if stats["n"] % 50 == 0:
                        f.flush()
                        print(f"  labeled {stats['n']}/{len(crops)}  tokens={stats['tokens']}  errors={stats['errors']}")
    finally:
        f.close()

    dt = time.time() - t0
    log = {
        "backend": args.backend,
        "labeled": stats["n"],
        "errors": stats["errors"],
        "total_tokens": stats["tokens"],
        "seconds": round(dt, 1),
        "crops_per_sec": round(stats["n"] / dt, 2) if dt else 0,
    }
    Path(args.out).with_suffix(".usage.json").write_text(json.dumps(log, indent=2))
    print(f"DONE: {json.dumps(log)}")


if __name__ == "__main__":
    main()
