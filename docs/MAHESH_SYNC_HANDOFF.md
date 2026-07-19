# ShelfSight sync handoff for `mahesh`

This runbook is for an agent that must append the current ShelfSight implementation to the
existing `mgrandhi/` integration and push it safely. This is **not** a fresh import and
`mgrandhi/` must not be replaced wholesale.

## Fixed repositories and branches

```bash
SOURCE=/Users/mgrandhi/Projects/retail-inventory-ai
TARGET=/Users/mgrandhi/Projects/dense-shelf-images-object-detection
SOURCE_BRANCH=main
TARGET_BRANCH=mahesh
REMOTE=origin
```

- Source of ShelfSight code: `$SOURCE`, current `main` working tree.
- Target of the integration: `$TARGET`, remote branch `origin/mahesh`.
- Destination package: `$TARGET/mgrandhi/`.
- Dense-repository model/data assets stay at the target repository root. Never copy them into
  `mgrandhi/`.

Local history is context only. At the time this runbook was written, source `main` was clean at
`origin/main`, while the target's local `mahesh` had unpublished commits beyond
`origin/mahesh`. Do not depend on either observation. Fetch again and build the change from the
current source files on top of the current remote target branch.

## Non-negotiable safety rules

1. Fetch and inspect `origin/mahesh` before editing.
2. Start from `origin/mahesh`, not the target's local `mahesh`, a local merge commit, or an
   unpublished commit hash.
3. Use a separate clean worktree. Do not clean, reset, stash, move, or stage files in the existing
   target checkout.
4. Preserve all remote work. Do not delete or replace `mgrandhi/`; update files deliberately.
5. Never use `git push --force`, `--force-with-lease`, `git reset --hard`, or broad cleanup.
6. Never run `git add .`, `git add -A`, or `git add mgrandhi`.
7. Never copy model, index, embedding, dataset, database, cache, build, dependency, or secret
   files. In particular, do not copy `*.pt`, `*.bin`, `*.npy`, `*.db`, `node_modules/`, `dist/`,
   `.venv/`, `.env`, caches, or datasets.
8. Do not modify dense root model assets or unrelated root application files.
9. Keep Python imports under the `mgrandhi.*` package and resolve dense-root assets through
   `mgrandhi/config/paths.py` or environment overrides.
10. Stop on an unexplained deletion, binary addition, merge conflict, failing check, missing
    asset mapping, authentication error, or remote update that cannot be reconciled safely.

## 1. Preflight and isolate the target

These commands are read-only until `git worktree add` creates the isolated checkout.

```bash
set -euo pipefail

SOURCE=/Users/mgrandhi/Projects/retail-inventory-ai
TARGET=/Users/mgrandhi/Projects/dense-shelf-images-object-detection

test -d "$SOURCE/.git"
test -d "$TARGET/.git"

git -C "$SOURCE" fetch origin main
git -C "$TARGET" fetch origin mahesh

git -C "$SOURCE" status --short --branch
test "$(git -C "$SOURCE" branch --show-current)" = "main"
git -C "$SOURCE" log -1 --decorate --oneline main
git -C "$SOURCE" log -1 --decorate --oneline origin/main

git -C "$TARGET" status --short --branch
git -C "$TARGET" log -1 --decorate --oneline origin/mahesh
git -C "$TARGET" log --graph --decorate --oneline --all -20
```

Review source changes with:

```bash
git -C "$SOURCE" diff --name-status
git -C "$SOURCE" diff --cached --name-status
git -C "$SOURCE" log --oneline origin/main..main
```

The current source working tree is authoritative, but record any uncommitted source changes in the
handoff/commit message. Do not assume an unpublished source commit can be fetched later. If source
changes are ambiguous, partially staged, or outside the mapping below, stop and ask the owner.

Create a clean target worktree directly from the fetched remote branch:

```bash
SYNC_ID="$(date -u +%Y%m%dT%H%M%SZ)"
WORKTREE="/tmp/dense-shelfsight-${SYNC_ID}"
SYNC_BRANCH="shelfsight-sync-${SYNC_ID}"

git -C "$TARGET" worktree add -b "$SYNC_BRANCH" "$WORKTREE" origin/mahesh
git -C "$WORKTREE" status --short --branch
test "$(git -C "$WORKTREE" merge-base HEAD origin/mahesh)" = \
     "$(git -C "$WORKTREE" rev-parse origin/mahesh)"
```

Do not continue unless the new worktree is clean.

## 2. Preserve and inspect the existing integration

```bash
ls -la "$WORKTREE/mgrandhi"
git -C "$WORKTREE" ls-files 'mgrandhi/**' | sort

sed -n '1,220p' "$WORKTREE/mgrandhi/README.md"
sed -n '1,220p' "$WORKTREE/mgrandhi/config/paths.py"
sed -n '1,220p' "$WORKTREE/mgrandhi/requirements.txt"
sed -n '1,220p' "$WORKTREE/mgrandhi/frontend/run_web_dev.sh"
sed -n '1,220p' "$WORKTREE/mgrandhi/frontend/run_web_ui.sh"
```

Also review remote changes since the last known integration when that base is known:

```bash
git -C "$WORKTREE" log --oneline --decorate -- mgrandhi
git -C "$WORKTREE" log -p -5 -- mgrandhi/config/paths.py mgrandhi/README.md
```

Remote edits win unless the current source intentionally supersedes the same behavior. Never
overwrite target-only path configuration, package adaptations, documentation, or teammate fixes
without understanding the difference.

## 3. Source-to-target mapping

Use this mapping as an allowlist. Copy/update files individually or use `rsync` **without**
`--delete`.

| Source | Target | Treatment |
|---|---|---|
| `backend/api.py`, `backend/analysis_service.py`, `backend/inventory_db.py`, `backend/llm_service.py`, `backend/__init__.py` | `mgrandhi/backend/` | Sync Python/schema files, including the new server-side LLM service; adapt imports. |
| `bi_interface/` | `mgrandhi/bi_interface/` | Sync package files; adapt imports if needed. |
| `retrieval/pipeline.py`, `retrieval/swin_faiss.py`, `retrieval/__init__.py` | `mgrandhi/retrieval/` | Sync logic, then retain dense-root asset resolution. |
| `frontend/app.py`, `frontend/gradio_app.py` | `mgrandhi/app.py`, `mgrandhi/gradio_app.py` | Sync legacy wrappers; adapt imports. |
| `frontend/run_hybrid_ui.sh` | `mgrandhi/run_hybrid_ui.sh` | Sync and retain root-aware launch behavior. |
| `frontend/deploy_hybrid_ui_gcp.sh` | `mgrandhi/deploy_hybrid_ui_gcp.sh` | Sync deployment updates, including stopped-VM restart; retain IAP-only defaults and dense-root assets. |
| `frontend/run_web_dev.sh`, `frontend/run_web_ui.sh` | `mgrandhi/frontend/` | Sync; commands must import `mgrandhi.backend.api`. |
| `frontend/web/` | `mgrandhi/frontend/web/` | Sync source/config/lockfile; exclude generated/dependency directories. |
| Selected `autolabel/sku_vlm*` and open-VLM launcher scripts | `mgrandhi/autolabel/` | Update only the already integrated SKU/VLM files. |
| `tests/test_analysis_service.py`, `tests/test_api.py`, `tests/test_inventory_db.py` | `mgrandhi/tests/` | Sync new/updated backend tests and change imports to `mgrandhi.*`. |
| `frontend/web/src/App.test.tsx`, `frontend/web/src/api.test.ts` | `mgrandhi/frontend/web/src/` | Sync routing, request-cancellation, and response-normalization regressions. |
| `docs/database_schema.md`, `docs/open_vlm_sku_benchmark.md` | `mgrandhi/docs/` | Merge relevant documentation; preserve target-only runbooks. |
| `demo/shelfsight-ui-demo.{png,webm}` | `mgrandhi/demo/` | Optional known UI documentation only; verify each is under 10 MiB. |
| `.env.example` | `mgrandhi/.env.example` | Merge supported variable names only; never copy values or `.env`. |
| `pyproject.toml` dependency declarations | `mgrandhi/requirements.txt` | Review and merge dependencies manually; do not copy `pyproject.toml`. |

This append adds the current Insights-first experience; it does not replace the existing
integration. `/` now canonicalizes to `/insights`, while upload and scan controls live on the
separate `/scan` route and the Insights page has a prominent scan CTA. Insights includes a
grounded overall inventory briefing plus a numeric narrative and data-supported administrator
actions for each chart. Both Insights summaries and per-scan SKU/OCR expose server-advertised
Gemini or OpenRouter provider/model choices, but they are separate requests and selections.

The backend now validates provider/model selections against server allowlists, accepts per-request
`sku_provider` and `sku_model` form fields, and uses `backend/llm_service.py` for provider
configuration, grounded summary generation, strict response validation, and deterministic
fallbacks. The frontend normalizes summary responses, treats absent or malformed action lists
safely, and aborts stale Insights/config/summary requests when navigation or regeneration makes
them obsolete. Include the scan-to-Insights regression fix: returning to Insights remounts the
page, reloads current inventory, and generates a fresh briefing rather than allowing an aborted or
older request to overwrite it.

Selected autolabel files are:

```text
autolabel/sku_vlm.py
autolabel/sku_vlm_benchmark.sh
autolabel/launch_sku_vlm_benchmark.sh
autolabel/open_vlm_endpoint_startup.sh
autolabel/launch_open_vlm_endpoint.sh
```

Explicitly exclude:

```text
.git/  .venv/  node_modules/  dist/  __pycache__/  .pytest_cache/
.env  *.db  *.sqlite*  data/  datasets/  artifacts/  outputs/  runs/
*.pt  *.pth  *.keras  *.bin  *.npy  *.safetensors
retrieval/assets/  retrieval/swin_faiss_index.bin
detection/artifacts/
```

Do not copy source root `README.md`, `PROJECT_MEMORY.md`, logs, notebooks, training code, datasets,
or `pyproject.toml`. Do not modify target root models, SWIN directories, FAISS files, CSV assets,
Gradio application, or unrelated teammate files. A small, deliberate target root `README.md`
addition is allowed only if the existing ShelfSight link/launch instructions need updating; never
replace that README with the source README.

An example safe frontend copy is:

```bash
mkdir -p "$WORKTREE/mgrandhi/frontend/web"
rsync -av --itemize-changes \
  --exclude='.git/' --exclude='node_modules/' --exclude='dist/' \
  --exclude='coverage/' --exclude='.env' --exclude='*.local' \
  "$SOURCE/frontend/web/" "$WORKTREE/mgrandhi/frontend/web/"
```

For every other mapping, prefer explicit `install -m 0644 SOURCE TARGET` commands and
`install -m 0755` for shell scripts. Do not use a repository-wide `cp` or `rsync`.

## 4. Required target adaptations

The dense repository is not an editable Python package. Launch scripts run from dense root so the
root is on `sys.path`; modules must therefore import:

```python
from mgrandhi.backend import analysis_service
from mgrandhi.backend import inventory_db
from mgrandhi.bi_interface import bi_engine
from mgrandhi.retrieval import pipeline
from mgrandhi.autolabel.sku_vlm import build_backend
from mgrandhi.config.paths import YOLO_WEIGHTS
```

Convert source imports such as `from backend`, `from retrieval`, `from autolabel`, or
`from bi_interface` to their `mgrandhi.*` equivalents, including tests and lazy imports.
In particular, adapt the new service imports in both backend callers:

```python
from mgrandhi.backend import llm_service
```

`mgrandhi/backend/llm_service.py` itself has no source-package import to rewrite, but it must remain
inside the `mgrandhi.backend` package so `api.py` and `analysis_service.py` share the same provider
allowlist and validation.

Retain `mgrandhi/config/paths.py` as the target boundary. Its defaults must resolve:

```text
models/yolo/best.pt
swin_faiss_index.bin
swin_faiss_indexed_image_paths.csv
swin_model_assets/
swin_processor_assets/
train_product_category_58.csv
```

from dense repository root. Keep environment overrides for `YOLO_WEIGHTS`, `FAISS_INDEX`,
`INDEXED_IMAGE_PATHS_CSV`, `SWIN_MODEL_DIR`, `SWIN_PROCESSOR_DIR`, `LABELS_CSV`,
`INVENTORY_DB`, `FEEDBACK_ASSET_DIR`, and `SHELFSIGHT_WEB_DIST`.

Keep runtime state under `mgrandhi/` by default:

```text
mgrandhi/inventory.db
mgrandhi/data/review_evidence/
mgrandhi/frontend/web/dist/
```

Ensure these generated paths remain ignored. Do not copy source package metadata: target setup is
`pip install -r mgrandhi/requirements.txt`, and launch modules are
`mgrandhi.backend.api:app`.

Treat all provider credentials as server-only runtime secrets. Never copy `.env`, credential
files, ADC material, tokens, or populated deployment configuration. Merge only variable names,
safe placeholders, comments, and defaults documented by source `.env.example`. In particular,
`OPENROUTER_API_KEY` must remain empty in tracked files and be injected only into the server/VM
runtime; provider keys must never appear in Vite variables, browser payloads, logs, or SQLite.

## 5. Audit the source/target diff

Before testing, review every target change:

```bash
git -C "$WORKTREE" status --short
git -C "$WORKTREE" diff --stat
git -C "$WORKTREE" diff --check
git -C "$WORKTREE" diff -- mgrandhi
git -C "$WORKTREE" diff -- README.md
```

Audit expected source differences as well:

```bash
git diff --no-index --stat "$SOURCE/backend" "$WORKTREE/mgrandhi/backend" || true
git diff --no-index --stat "$SOURCE/frontend/web" "$WORKTREE/mgrandhi/frontend/web" || true
git diff --no-index --stat "$SOURCE/tests" "$WORKTREE/mgrandhi/tests" || true
```

Differences should be explainable by the directory mapping, `mgrandhi.*` imports, dense-root path
configuration, target requirements, or preserved remote work. Investigate every deletion:

```bash
git -C "$WORKTREE" diff --diff-filter=D --name-status
git -C "$WORKTREE" ls-files --others --exclude-standard
```

There should be no deletion unless explicitly approved. Check for accidentally added large files:

```bash
while IFS= read -r -d '' path; do
  du -h "$WORKTREE/$path"
done < <(git -C "$WORKTREE" ls-files --others --exclude-standard -z)
git -C "$WORKTREE" diff --numstat
```

Only the two known demo files may be binary additions, and only after confirming they are UI
documentation and each is under 10 MiB. No model/data binary is allowed.

## 6. Verify

From dense repository root:

```bash
cd "$WORKTREE"

SYNC_VENV="/tmp/dense-shelfsight-venv-${SYNC_ID}"
python3.11 -m venv "$SYNC_VENV"
source "$SYNC_VENV/bin/activate"
python -m pip install --upgrade pip
python -m pip install -r mgrandhi/requirements.txt

git lfs install
git lfs pull
git lfs checkout

test -s models/yolo/best.pt
test -s swin_faiss_index.bin
test -s swin_faiss_indexed_image_paths.csv
test -s swin_model_assets/model.safetensors
test -s swin_processor_assets/preprocessor_config.json
test -s train_product_category_58.csv

npm --prefix mgrandhi/frontend/web ci
python -m compileall -q mgrandhi
python -m pytest -q \
  mgrandhi/tests/test_analysis_service.py \
  mgrandhi/tests/test_api.py \
  mgrandhi/tests/test_inventory_db.py
npm --prefix mgrandhi/frontend/web test -- \
  src/App.test.tsx src/api.test.ts
npm --prefix mgrandhi/frontend/web run typecheck
npm --prefix mgrandhi/frontend/web run lint
npm --prefix mgrandhi/frontend/web run build
bash -n mgrandhi/frontend/*.sh mgrandhi/run_hybrid_ui.sh \
  mgrandhi/deploy_hybrid_ui_gcp.sh
PRELOAD_MODELS=0 python -c \
  "from mgrandhi.backend.api import app; print(app.title)"
```

Optional smoke test without model preloading:

```bash
PRELOAD_MODELS=0 \
  uvicorn mgrandhi.backend.api:app --host 127.0.0.1 --port 8000
```

In another shell:

```bash
curl --fail --silent http://127.0.0.1:8000/api/health
curl --fail --silent http://127.0.0.1:8000/api/insights
curl --fail --silent http://127.0.0.1:8000/api/ai-config
curl --fail --silent http://127.0.0.1:8000/insights >/dev/null
curl --fail --silent http://127.0.0.1:8000/scan >/dev/null

# With Gemini configured, request a grounded briefing. Without credentials/provider access,
# the same endpoint must return HTTP 200 with source=deterministic and a warning.
curl --fail --silent \
  -H 'Content-Type: application/json' \
  -d '{"provider":"gemini","model":"gemini-2.5-flash"}' \
  http://127.0.0.1:8000/api/insight-summaries
```

Confirm the provider-options response contains no key or credential values. Confirm the summary
contains `overall_summary` and all five chart IDs; for a successful provider call its `source` is
`llm`, while unavailable, failed, or malformed provider output must yield `source=deterministic`
with grounded chart narratives/actions and a warning. The React test suite verifies `/` becomes
`/insights`, `/scan` remains separate, response normalization is defensive, stale requests are
cancelled, and returning from Scan refreshes Insights.

Stop the server with Ctrl-C. A real scan is a separate GPU/resource-sensitive check and requires
the LFS assets. If it is run, submit `sku_provider` and an allowlisted `sku_model`, poll the returned
job, then navigate back to `/insights` and confirm the new scan appears without a hard refresh.

## 7. Conflicts and remote movement

Do not resolve conflicts by taking all of source or all of target.

- Preserve remote target structure, target-only fixes, and dense-root paths.
- Apply current source behavior file by file.
- For import/path conflicts, use `mgrandhi.*` and `mgrandhi/config/paths.py`.
- For schema conflicts, preserve existing data and additive migrations; never delete a database.
- For frontend lockfile conflicts, reconcile `package.json`, regenerate with the approved npm
  registry if necessary, and rerun all frontend checks.
- If intent is unclear, abort the operation and report the exact files and conflict hunks.

## 8. Stage, commit, refresh, and push

First list all changed and untracked paths. Build an explicit approved path list from that output:

```bash
cd "$WORKTREE"
git status --short
git diff --name-only
git ls-files --others --exclude-standard
```

Stage each approved file explicitly, for example:

```bash
git add -- \
  mgrandhi/backend/api.py \
  mgrandhi/backend/analysis_service.py \
  mgrandhi/frontend/run_web_dev.sh \
  mgrandhi/frontend/run_web_ui.sh
```

Repeat with the exact approved paths. Never stage `.venv`, generated `dist`, databases,
evidence, caches, assets, or unrelated untracked files. Then inspect the index:

```bash
git diff --cached --name-status
git diff --cached --stat
git diff --cached --check
git diff --cached
```

Commit only after the staged diff is complete and checks pass:

```bash
git commit -m "Update ShelfSight integration"
```

Refresh the remote immediately before pushing:

```bash
git fetch origin mahesh
git rebase origin/mahesh
```

If rebase conflicts, follow the conflict rules, rerun the full checks, and continue only when every
resolution is understood. Verify fast-forward topology:

```bash
test "$(git merge-base HEAD origin/mahesh)" = "$(git rev-parse origin/mahesh)"
git log --graph --decorate --oneline origin/mahesh..HEAD
git diff --stat origin/mahesh..HEAD
```

Push normally:

```bash
git push origin HEAD:mahesh
```

If rejected as non-fast-forward, do not force. Fetch, rebase onto the new `origin/mahesh`, resolve,
retest, and retry the same normal push.

## 9. Recovery and blockers

- Existing target checkout changed: leave it untouched; continue only in the isolated worktree.
- Remote `mahesh` changed: fetch/rebase in the isolated worktree; never overwrite remote work.
- Accidental unstaged copy in the isolated worktree: inspect it and remove only that known new
  file. Never run a repository-wide clean/reset command.
- Wrong file staged: `git restore --staged -- <exact-path>`, then inspect the working copy.
- Commit created but not pushed: fix with a new commit unless the owner explicitly authorizes an
  amend.
- Push/auth failure: report the command and error; do not change remotes, credentials, or Git
  configuration.
- Missing LFS objects, model files, registry access, required secrets, or unclear source changes:
  stop and report the blocker. Do not fabricate files or credentials.

After a successful push, remove only the temporary worktree and branch after confirming no work is
left there:

```bash
git -C "$WORKTREE" status --short
rm -rf "$SYNC_VENV"
git -C "$TARGET" worktree remove "$WORKTREE"
git -C "$TARGET" branch -d "$SYNC_BRANCH"
```
