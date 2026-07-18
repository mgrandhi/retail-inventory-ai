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
  ├─ optional SKU/OCR backend
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
SKU_BACKEND=dry-run \
bash mgrandhi/frontend/run_web_dev.sh
```

Open <http://localhost:5173>. The script starts:

- FastAPI at `http://127.0.0.1:8000`
- Vite at `http://127.0.0.1:5173`
- a Vite `/api` proxy to FastAPI

`SKU_BACKEND=dry-run` avoids external SKU/OCR credentials while leaving YOLO and SWIN/FAISS
category inference enabled. The script stops both processes if either exits.

## Production-style single-origin mode

From dense root:

```bash
SKU_BACKEND=dry-run \
bash mgrandhi/frontend/run_web_ui.sh
```

The script builds `mgrandhi/frontend/web/dist/`, then FastAPI serves the React application and API
from <http://localhost:8000>.

To reuse an existing successful frontend build or change the port:

```bash
SKIP_WEB_BUILD=1 \
WEB_PORT=8080 \
SKU_BACKEND=dry-run \
bash mgrandhi/frontend/run_web_ui.sh
```

Open <http://localhost:8080>. Use `SKIP_WEB_BUILD=1` only when
`mgrandhi/frontend/web/dist/index.html` already exists and matches the current frontend.

## Health checks

With either mode running:

```bash
curl --fail --silent http://127.0.0.1:8000/api/health
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
PRELOAD_MODELS=0 SKU_BACKEND=dry-run \
uvicorn mgrandhi.backend.api:app --host 127.0.0.1 --port 8000
```

## Environment overrides

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

The UI can override classification and SKU crop limits per scan. Keep one Uvicorn worker: model
objects are process-local and each worker would load the large assets separately.

## SKU/OCR backend options

Do not put secrets in shell history, tracked files, screenshots, or issue comments. Prefer your
environment's secret manager or an untracked environment file loaded by your process supervisor.

### No external service

Use this for setup and UI testing:

```bash
export SKU_BACKEND=dry-run
export SKU_MODEL=dry-run
```

To prevent server-side SKU preloading and disable extraction for API callers that omit the flag:

```bash
export SKU_EXTRACT_DEFAULT=0
```

The React UI starts with SKU reading checked and sends its selection explicitly. The operator must
uncheck **Read SKU and package text** for a scan, or use `SKU_BACKEND=dry-run`, when no remote SKU
service should be called.

### Vertex Gemini

This is the application's default backend. It uses Google Application Default Credentials, not an
API key:

```bash
export SKU_BACKEND=gemini
export PROJECT_ID=your-authorized-gcp-project
export REGION=us-central1
export VERTEX_MODEL=gemini-2.5-flash
```

Authenticate outside the repository using the approved user or workload identity flow. The
principal needs permission to invoke the selected Vertex model. Do not paste tokens into config.

### OpenAI-compatible Qwen/PaliGemma endpoint

```bash
export SKU_BACKEND=openai-compatible
export VLM_ENDPOINT_URL=https://your-authorized-host.example/v1
export VLM_MODEL=Qwen/Qwen2.5-VL-3B-Instruct
```

If the endpoint requires a bearer token, provide `VLM_API_KEY` through a secret manager or the
runtime environment. It may be empty for an endpoint that does not require authentication.

### Vertex Model Garden endpoint

```bash
export SKU_BACKEND=vertex-model-garden
export PROJECT_ID=your-authorized-gcp-project
export REGION=us-central1
export VERTEX_MODEL_GARDEN_ENDPOINT_ID=your-deployed-endpoint-id
export VERTEX_MODEL_GARDEN_MODEL=google/paligemma@paligemma-mix-448-float16
```

For a dedicated endpoint, set `VERTEX_MODEL_GARDEN_DEDICATED_DNS` to its authorized hostname.
This backend also uses Google credentials. Managed endpoints may incur charges while deployed;
follow the owning team's shutdown policy.

For all remote backends:

```bash
export SKU_TIMEOUT_SECONDS=180
```

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

- With `dry-run`, empty SKU fields are expected.
- With Gemini, verify `PROJECT_ID`, Google authentication, region, and model access.
- With an OpenAI-compatible service, verify the `/v1` endpoint, model name, network access, and
  secret injection.
- With Model Garden, verify endpoint ID, region, project, dedicated DNS if applicable, and IAM.
- Check the FastAPI log for timeout or backend errors.

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
