# Run ShelfSight from the dense repository

ShelfSight is the React operator UI and FastAPI service under `mgrandhi/`. It reuses the dense
repository's root-level YOLO, SWIN, FAISS, and label assets; those files must not be duplicated
under `mgrandhi/`.

All commands in this guide start from the dense repository root:

```bash
cd /path/to/dense-shelf-images-object-detection
```

No setup or launch step requires `cd mgrandhi`. If you enter `mgrandhi/` only to inspect files,
return to dense root before running Python, Uvicorn, npm, or a launch script.

## Architecture and paths

```text
browser
  ├─ development: Vite :5173 ──proxy /api──> FastAPI :8000
  └─ production:  FastAPI :8000 serves both /api and built React files

FastAPI (mgrandhi.backend.api)
  ├─ YOLO detector
  ├─ SWIN encoder + FAISS retrieval
  ├─ Gemini/OpenRouter SKU/OCR backend
  ├─ grounded inventory narratives with deterministic fallback
  └─ SQLite inventory + review evidence
```

`mgrandhi/config/paths.py` derives dense root from its own location. Its default asset paths are:

```text
models/yolo/best.pt
swin_faiss_index.bin
swin_faiss_indexed_image_paths.csv
swin_model_assets/
swin_model_assets/model.safetensors
swin_processor_assets/
swin_processor_assets/preprocessor_config.json
train_product_category_58.csv
```

The first path is relative to dense root, not `mgrandhi/`. The launch scripts change to dense root
before importing `mgrandhi.*`; this repository is not installed as an editable Python package.

## Routes and operator flow

Insights is the default landing page. Opening `/` performs a client-side canonical redirect to
`/insights`; it is not the upload page. The primary routes are:

- `/insights`: current inventory metrics, charts, overall briefing, chart narratives, and
  administrator actions.
- `/scan`: shelf-photo upload, per-scan analysis controls, progress, and the completed report.
- `/history`: saved scan history.
- `/ask`: natural-language inventory questions.

Use **Upload and scan a shelf** on Insights, or **Scan shelf** in the navigation, to enter
`/scan`. A completed scan remains visible on that route. Select **Insights** to return; the page
reloads the latest inventory and generates a fresh briefing. The fixed navigation behavior aborts
requests belonging to the previous Insights mount, so a stale response cannot overwrite the
newly loaded post-scan data.

## Prerequisites

- Git and Git LFS
- Python 3.11 (the ML stack requires Python 3.10 or 3.11)
- Node.js 22 LTS and npm (Vite 8 requires a current Node release)
- Bash 4.3 or newer for the development script's multi-process `wait -n`
- Enough disk and RAM for the approximately 2 GiB FAISS index and model files
- A CUDA-capable system is recommended for real inference; CPU inference is slower

Confirm tools:

```bash
git --version
git lfs version
python3.11 --version
node --version
npm --version
bash --version
```

## Fetch Git LFS assets

From dense root:

```bash
git lfs install
git lfs pull
git lfs checkout
```

Verify the exact required files:

```bash
test -s models/yolo/best.pt
test -s swin_faiss_index.bin
test -s swin_faiss_indexed_image_paths.csv
test -s swin_model_assets/model.safetensors
test -s swin_processor_assets/preprocessor_config.json
test -s train_product_category_58.csv
```

If a `test` command fails, do not copy an asset into `mgrandhi/`. Restore it at the expected dense
root path with Git LFS, or set the corresponding path override described below.

## Python environment

Create the virtual environment at dense root:

```bash
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r mgrandhi/requirements.txt
```

On subsequent runs:

```bash
cd /path/to/dense-shelf-images-object-detection
source .venv/bin/activate
```

Do not run `pip install -e mgrandhi`; `mgrandhi/` has no standalone `pyproject.toml`.

## Frontend installation and checks

Still from dense root:

```bash
npm --prefix mgrandhi/frontend/web ci
npm --prefix mgrandhi/frontend/web run typecheck
npm --prefix mgrandhi/frontend/web run lint
npm --prefix mgrandhi/frontend/web test
npm --prefix mgrandhi/frontend/web run build
```

`npm ci` uses the committed lockfile. If its configured package registry is inaccessible, use the
registry approved for your environment; do not commit credentials or an incidental lockfile
rewrite.

## Development mode: FastAPI plus Vite

From dense root, with the Python environment active:

```bash
PROJECT_ID=your-authorized-gcp-project \
bash mgrandhi/frontend/run_web_dev.sh
```

Open <http://localhost:5173>. The script starts:

- FastAPI at `http://127.0.0.1:8000`
- Vite at `http://127.0.0.1:5173`
- a Vite `/api` proxy to FastAPI

Gemini is advertised as available only when the server has `PROJECT_ID` or
`GOOGLE_CLOUD_PROJECT`; real requests also require valid ADC and model access. To develop without
provider credentials, start with `PRELOAD_MODELS=0` and use the read-only routes/API smoke checks
below. Provider-dependent scan controls remain unavailable until a configured provider is
selected. The script stops both processes if either exits.

## Production-style single-origin mode

From dense root:

```bash
PROJECT_ID=your-authorized-gcp-project \
bash mgrandhi/frontend/run_web_ui.sh
```

The script builds `mgrandhi/frontend/web/dist/`, then FastAPI serves the React application and API
from <http://localhost:8000>.

To reuse an existing successful frontend build or change the port:

```bash
SKIP_WEB_BUILD=1 \
WEB_PORT=8080 \
PROJECT_ID=your-authorized-gcp-project \
bash mgrandhi/frontend/run_web_ui.sh
```

Open <http://localhost:8080>. Use `SKIP_WEB_BUILD=1` only when
`mgrandhi/frontend/web/dist/index.html` already exists and matches the current frontend.

## Deploy to a GCP VM

From dense root, use the adapted deployment script:

```bash
PROJECT_ID=your-authorized-gcp-project \
ZONE=us-central1-a \
INSTANCE=retail-inventory-ui-gpu \
bash mgrandhi/deploy_hybrid_ui_gcp.sh
```

The script reuses an existing VM and now starts it when it exists but is stopped. Its safe default
is still IAP-only: no external IP, UI access limited to the IAP range, and outbound access through
Cloud NAT. Do not set `PUBLIC_ACCESS=1` for a normal deployment. Open the printed tunnel from the
operator machine:

```bash
gcloud compute start-iap-tunnel retail-inventory-ui-gpu 8000 \
  --local-host-port=localhost:8000 \
  --zone us-central1-a \
  --project your-authorized-gcp-project
```

Then open <http://localhost:8000/insights>. Provider credentials must be injected into the VM
service environment; do not package `.env`, ADC files, or keys with the application.

## Health checks

With either mode running:

```bash
curl --fail --silent http://127.0.0.1:8000/api/health
curl --fail --silent http://127.0.0.1:8000/api/insights
curl --fail --silent http://127.0.0.1:8000/api/ai-config
curl --fail --silent http://127.0.0.1:8000/insights >/dev/null
curl --fail --silent http://127.0.0.1:8000/scan >/dev/null
```

Typical model states:

- `loading`: background model preload is still running.
- `ready`: detector and classifier loaded successfully.
- `degraded`: preload failed; inspect the server log and asset paths.
- `lazy`: the server was started with `PRELOAD_MODELS=0`.

An API/import-only check that does not load model assets:

```bash
PRELOAD_MODELS=0 python -c \
  "from mgrandhi.backend.api import app; print(app.title)"
```

For a lightweight API health server:

```bash
PRELOAD_MODELS=0 \
uvicorn mgrandhi.backend.api:app --host 127.0.0.1 --port 8000
```

Generate a summary with an allowlisted model:

```bash
curl --fail --silent \
  -H 'Content-Type: application/json' \
  -d '{"provider":"gemini","model":"gemini-2.5-flash"}' \
  http://127.0.0.1:8000/api/insight-summaries
```

With working ADC/model access, the response reports `source: "llm"`. If the provider is
unavailable, times out, fails, or returns malformed/incomplete JSON, the endpoint still returns a
grounded `source: "deterministic"` response with a warning, an overall summary, and all five chart
narratives/actions.

For a browser smoke check, open `/`, confirm the address becomes `/insights`, use the scan CTA and
confirm it opens `/scan`, then return with the **Insights** navigation item. The latest scan and
briefing must refresh without a hard reload.

## Environment overrides

### Variables documented by the current `.env.example`

Copy only this tracked template's variable names and safe defaults into target documentation.
Never copy a populated `.env` or credentials. The current template contains:

```dotenv
PROJECT_ID=your-gcp-project-id
REGION=us-central1
ZONE=us-central1-a
BUCKET=gs://your-gcp-project-id-sku110k-yolo
DATASETS_BUCKET=gs://your-gcp-project-id-datasets
VERTEX_MODEL=gemini-2.5-flash
GEMINI_MODEL=gemini-2.5-flash
GEMINI_MODELS=gemini-2.5-flash
SKU_PROVIDER=gemini
OPENROUTER_API_KEY=
OPENROUTER_BASE_URL=https://openrouter.ai/api/v1
OPENROUTER_MODEL=google/gemini-2.5-flash
OPENROUTER_MODELS=google/gemini-2.5-flash
OPENROUTER_SITE_URL=
OPENROUTER_APP_NAME=ShelfSight
LLM_TIMEOUT_SECONDS=60
API_KEY=change-me-dev-api-key
DATABASE_URL=sqlite:///./inventory.db
OLLAMA_HOST=http://localhost:11434
OLLAMA_MODEL=llama3.1:8b
```

Placeholders such as `your-gcp-project-id` and `change-me-dev-api-key` are documentation, not
production values. Some variables support other project modules; the ShelfSight provider controls
use the variables described below.

### Dense-root paths and service controls

Path defaults come from `mgrandhi/config/paths.py`. Values may be absolute paths or paths relative
to the process working directory; absolute paths are safer:

```bash
export YOLO_WEIGHTS=/absolute/path/to/best.pt
export FAISS_INDEX=/absolute/path/to/swin_faiss_index.bin
export INDEXED_IMAGE_PATHS_CSV=/absolute/path/to/swin_faiss_indexed_image_paths.csv
export SWIN_MODEL_DIR=/absolute/path/to/swin_model_assets
export SWIN_PROCESSOR_DIR=/absolute/path/to/swin_processor_assets
export LABELS_CSV=/absolute/path/to/train_product_category_58.csv
```

Runtime storage can also be relocated:

```bash
export INVENTORY_DB=/absolute/writable/path/inventory.db
export FEEDBACK_ASSET_DIR=/absolute/writable/path/review_evidence
export SHELFSIGHT_WEB_DIST=/absolute/path/to/frontend/dist
```

Common service controls:

```bash
export PRELOAD_MODELS=1
export YOLO_CONFIDENCE=0.25
export MAX_CLASSIFICATION_CROPS=60
export MAX_SKU_CROPS=5
export SKU_EXTRACT_DEFAULT=1
export MAX_PENDING_SCANS=3
export MAX_UPLOAD_BYTES=15728640
export MAX_IMAGE_PIXELS=50000000
export DEV_CORS_ORIGINS=http://localhost:5173
```

The UI overrides classification and SKU crop limits per scan and sends its selected
`sku_provider`/`sku_model` with that scan. Keep one Uvicorn worker: model objects are process-local
and each worker would load the large assets separately.

## LLM and SKU/OCR provider controls

Do not put secrets in shell history, tracked files, screenshots, or issue comments. Prefer your
environment's secret manager or an untracked environment file loaded by your process supervisor.

### Vertex Gemini

Gemini is the default provider for both inventory summaries and per-scan SKU/OCR. It uses Google
Application Default Credentials and a project, not a browser API key:

```bash
export PROJECT_ID=your-authorized-gcp-project
export REGION=us-central1
export GEMINI_MODEL=gemini-2.5-flash
export GEMINI_MODELS=gemini-2.5-flash
export SKU_PROVIDER=gemini
```

`GEMINI_MODELS` is the comma-separated server allowlist shown in both selectors;
`GEMINI_MODEL` is its default. `GEMINI_MODEL` falls back to `VERTEX_MODEL`, then
`gemini-2.5-flash`. The provider is marked available when `PROJECT_ID` or
`GOOGLE_CLOUD_PROJECT` exists. `REGION` defaults to `us-central1`.

Authenticate outside the repository using the approved user or workload identity flow. The
principal needs permission to invoke the selected Vertex model. Do not paste tokens into config.

### OpenRouter

```bash
export OPENROUTER_API_KEY=use-runtime-secret-injection
export OPENROUTER_BASE_URL=https://openrouter.ai/api/v1
export OPENROUTER_MODEL=google/gemini-2.5-flash
export OPENROUTER_MODELS=google/gemini-2.5-flash
export OPENROUTER_SITE_URL=
export OPENROUTER_APP_NAME=ShelfSight
```

OpenRouter is available only when the server has `OPENROUTER_API_KEY`. Its base URL is restricted
to the official `https://openrouter.ai/api/v1` endpoint. `OPENROUTER_MODELS` is the comma-separated
allowlist and `OPENROUTER_MODEL` is its default. `OPENROUTER_SITE_URL` and
`OPENROUTER_APP_NAME` optionally set attribution headers. Keep the key in a VM secret,
process-supervisor secret, or equivalent server runtime injection. No key, ADC token, or
credential is returned by `/api/ai-config` or sent in browser requests.

`LLM_TIMEOUT_SECONDS` defaults to 60 seconds for inventory narratives.
`SKU_TIMEOUT_SECONDS` defaults in code to 180 seconds for each product-crop vision request.

### Selection and fallback behavior

The Insights provider/model controls affect only `POST /api/insight-summaries`. The `/scan`
**OCR provider** and **OCR model** controls affect only SKU/package extraction submitted with
`POST /api/analyses`; YOLO detection and SWIN/FAISS category matching are unchanged. A scan can
also disable **Read SKU and package text**. `SKU_PROVIDER=gemini` selects the server's preload
default, while each UI scan sends an explicit provider/model.

Both APIs reject unsupported providers or models not present in the selected server allowlist.
For inventory summaries, unavailable providers, network/model errors, and malformed or incomplete
model JSON fall back deterministically to the aggregated inventory facts. The fallback includes an
overall summary, per-chart narratives, and only data-supported administrator actions. For
SKU/OCR, a provider failure preserves category results, returns empty review-marked SKU fields,
and shows a package-reading warning rather than discarding the scan.

The benchmark CLI still supports dry-run, generic OpenAI-compatible, and Vertex Model Garden
backends, but those are not choices in the current ShelfSight browser UI.

## Insights narratives and refresh

The Insights page always loads deterministic chart data from `GET /api/insights`. It separately
loads provider availability/model allowlists and requests a grounded narrative. The result shows:

- one overall inventory summary;
- a numeric narrative for category frequency, shelf composition, products by scan, possible empty
  shelf area, and subcategory breakdown;
- administrator actions per chart when aggregated data supports action, otherwise **No immediate
  action**;
- whether the narrative came from the selected provider/model or the deterministic fallback.

Changing a provider resets the model to that provider's server default. Changing provider/model
does not immediately rewrite the existing briefing; select **Generate** to refresh it. Repeated
generation cancels the previous request, and navigating away cancels all active Insights requests.
Returning to Insights performs a fresh data/config/summary load, which is the regression fix for a
scan completed between visits.

## Optional inventory question backend

Inventory questions always have a deterministic rule-based path. If Ollama is available, the
service can use it first:

```bash
export BI_USE_LLM=1
export OLLAMA_BASE_URL=http://127.0.0.1:11434
export OLLAMA_MODEL=llama3.1:8b
```

Set `BI_USE_LLM=0` to use only rule-based answers.

## Persistence

Default writable paths are:

```text
mgrandhi/inventory.db
mgrandhi/data/review_evidence/scan_<id>/source.jpg
mgrandhi/data/review_evidence/scan_<id>/crop_<id>.jpg
```

SQLite stores scans, detections, feedback, and evidence paths. The evidence directory stores source
images and crops used for human review. Both may contain sensitive retail imagery; protect,
retain, and delete them according to team policy. They are runtime state and must not be committed.

To use a dedicated persistent location:

```bash
mkdir -p "$HOME/.local/share/shelfsight/review_evidence"
export INVENTORY_DB="$HOME/.local/share/shelfsight/inventory.db"
export FEEDBACK_ASSET_DIR="$HOME/.local/share/shelfsight/review_evidence"
```

Do not delete an existing database merely to address a schema mismatch. Startup performs additive
column migrations for supported older databases; back up persistent data before manual changes.

## Troubleshooting

### Import error for `mgrandhi`

Run the launch command from dense root. Do not `cd mgrandhi` before starting Uvicorn:

```bash
cd /path/to/dense-shelf-images-object-detection
source .venv/bin/activate
PRELOAD_MODELS=0 python -c "import mgrandhi.backend.api"
```

### LFS pointer or missing model/index

Check file type and size, then repeat the LFS checkout:

```bash
git lfs pull
git lfs checkout
ls -lh models/yolo/best.pt swin_faiss_index.bin \
  swin_model_assets/model.safetensors
```

A tiny text file beginning with the Git LFS specification is a pointer, not the model content.

### Health is `degraded`

Read the FastAPI log first. Verify every expected path and any override:

```bash
python - <<'PY'
from mgrandhi.config import paths
for name in (
    "YOLO_WEIGHTS", "FAISS_INDEX", "INDEXED_IMAGE_PATHS_CSV",
    "SWIN_MODEL_DIR", "SWIN_PROCESSOR_DIR", "LABELS_CSV",
):
    path = getattr(paths, name)
    print(f"{name}: {path} exists={path.exists()}")
PY
```

### macOS OpenMP duplicate-library abort

The launch scripts already default these values:

```bash
export KMP_DUPLICATE_LIB_OK=TRUE
export OMP_NUM_THREADS=1
```

Use the provided scripts so the settings and root working directory are applied consistently.

### SKU fields are empty

- With Gemini, verify `PROJECT_ID`, Google authentication, region, and model access.
- With OpenRouter, verify server-side `OPENROUTER_API_KEY`, the official base URL, allowlisted
  model, network access, and optional attribution settings.
- Confirm **Read SKU and package text** was enabled and the scan's selected provider was marked
  available.
- Check the FastAPI log for timeout or backend errors.

### AI provider options do not load

Call the current endpoint directly:

```bash
curl --fail --silent http://127.0.0.1:8000/api/ai-config
```

The response should contain only provider names, model allowlists, availability, descriptions, and
unavailable reasons. If a provider is unexpectedly unavailable, verify its server environment:
Gemini needs a project plus working ADC; OpenRouter needs `OPENROUTER_API_KEY`. Do not troubleshoot
by placing a key in the browser or a `VITE_*` variable.

### Narrative shows deterministic fallback

This is expected when the selected provider is unavailable, rejects the request, times out, or
returns malformed/incomplete content. Check the response `warning`, then inspect server logs
without logging credentials or raw authorization headers. Verify the model appears in
`GEMINI_MODELS` or `OPENROUTER_MODELS`, and verify `LLM_TIMEOUT_SECONDS` is suitable. The charts
remain usable because fallback text is generated from the same aggregated `/api/insights` data.

### Narrative refresh appears stale

Navigate away from Insights and back, or select **Generate** once. Current code aborts superseded
requests and ignores late responses. If old data still appears, confirm the latest frontend build
is served and rerun:

```bash
npm --prefix mgrandhi/frontend/web test -- \
  src/App.test.tsx src/api.test.ts
npm --prefix mgrandhi/frontend/web run build
```

### Vite loads but API calls fail

Confirm FastAPI health on port 8000 and that Vite was started with the provided development script:

```bash
curl --fail http://127.0.0.1:8000/api/health
```

If the browser origin differs from the default, set `DEV_CORS_ORIGINS` to a comma-separated list
before starting FastAPI. Do not use a wildcard in a shared environment.

### Production root returns 404

Build the frontend and restart:

```bash
npm --prefix mgrandhi/frontend/web run build
bash mgrandhi/frontend/run_web_ui.sh
```

Verify `mgrandhi/frontend/web/dist/index.html` exists, or check `SHELFSIGHT_WEB_DIST`.

### npm registry or lockfile failure

Confirm Node/npm versions and access to the registry encoded by the committed lockfile. Use only an
approved registry. Do not commit tokens, `.npmrc` credentials, `node_modules/`, or an unexplained
lockfile rewrite.

### Port already in use

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN
lsof -nP -iTCP:5173 -sTCP:LISTEN
```

Stop the process you own. Production mode can use another `WEB_PORT`; development scripts expect
FastAPI on 8000 and Vite on 5173.

### Development script exits at `wait -n`

The development launcher requires Bash 4.3 or newer. macOS ships an older system Bash; install an
approved current Bash and invoke the script with its absolute executable path, for example:

```bash
/opt/homebrew/bin/bash mgrandhi/frontend/run_web_dev.sh
```

Use the path provided by your package manager (`command -v bash`) rather than assuming the example
path exists.

## Shutdown

For either provided launch script, press Ctrl-C in its terminal. The development script traps the
signal and stops both FastAPI and Vite.

If a child process remains, identify it before stopping it:

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN
lsof -nP -iTCP:5173 -sTCP:LISTEN
```

Do not stop shared model endpoints, cloud VMs, or Ollama services unless you own them and their
shutdown procedure requires it.
