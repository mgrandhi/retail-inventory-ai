#!/bin/bash
# VM startup script — runs as root on first boot. Labels a sample of one SPLIT's crops with the
# Vertex Gemini VLM (chosen over CLIP by the 2026-06-27 decision gate). The resulting CSV is the
# teacher-label set the two-head classifier trains on.
#
# Mirrors classification/crop_sku110k.sh's hard-won patterns:
#   - COST SAFETY: an EXIT trap ALWAYS syncs label CSVs to GCS and self-deletes the VM (3 layers).
#   - LOGGING: heavy output goes DIRECTLY to a file (>> "$LOG" 2>&1), never through the GCP
#     metadata script-runner's stdout (its bufio.Scanner caps lines at 64KB; tqdm \r progress
#     bars overflow it -> "token too long" -> the runner kills the child). Only short echoes go
#     to the console.
#
# Image: pytorch-2-9-cu129-ubuntu-2204-nvidia-580 (Deep Learning VM) — torch is preinstalled.
# Placeholders substituted by launch_labels.sh before upload:
#   __BUCKET__       results bucket. Crops at $BUCKET/crops/<split>_crops.tar; labels -> $BUCKET/labels/.
#   __REPO_TARBALL__ gs:// path to a tarball of classification/ + autolabel/ code.
#   __SPLIT__        which split to label: train | val | test.
#   __LABEL_LIMIT__  how many crops to label with Gemini (0 = all). Sampled from the sorted prefix.
#   __VERTEX_MODEL__ Vertex model id (e.g. gemini-2.5-flash).
#   __WORKERS__      Gemini concurrent request workers.
set -uo pipefail

BUCKET="__BUCKET__"
REPO_TARBALL="__REPO_TARBALL__"
SPLIT="__SPLIT__"
LABEL_LIMIT="__LABEL_LIMIT__"
VERTEX_MODEL="__VERTEX_MODEL__"
WORKERS="__WORKERS__"

RUN_DIR=/opt/runs
LOG="$RUN_DIR/labels.log"
OUT_DIR="$RUN_DIR/labels"
CROPS_DIR="$RUN_DIR/crops/$SPLIT"
OUT_CSV="$OUT_DIR/labels_gemini_${SPLIT}.csv"
mkdir -p "$RUN_DIR" "$OUT_DIR" "$CROPS_DIR"
: > "$LOG"

# --- COST-SAFETY TRAP: always sync labels + self-delete on ANY exit ---------
cleanup() {
  rc=$?
  echo "=== cleanup (exit code $rc): syncing labels to GCS ==="
  gsutil -m rsync -r "$OUT_DIR" "$BUCKET/labels/" || echo "WARN: labels sync failed"
  gsutil cp "$LOG" "$BUCKET/labels/labels_${SPLIT}.log" || true

  NAME=$(curl -sf -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/name)
  ZONE_PATH=$(curl -sf -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/zone)
  ZONE=$(echo "$ZONE_PATH" | awk -F/ '{print $NF}')
  PROJECT=$(curl -sf -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/project/project-id)
  TOKEN=$(curl -sf -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

  apt-get install -y at >/dev/null 2>&1 || true
  echo "shutdown -h now" | at now + 5 minutes 2>/dev/null || (sleep 300 && shutdown -h now) &

  echo "=== deleting self via gcloud: $NAME in $ZONE ==="
  gcloud compute instances delete "$NAME" --zone "$ZONE" --quiet || echo "WARN: gcloud delete failed"
  sleep 30
  echo "=== fallback: deleting self via REST API ==="
  curl -sf -X DELETE -H "Authorization: Bearer $TOKEN" \
    "https://compute.googleapis.com/compute/v1/projects/$PROJECT/zones/$ZONE/instances/$NAME" \
    || echo "WARN: REST delete failed"
}
trap cleanup EXIT

echo "=== retail-inventory-ai: $SPLIT crop labeling STARTED ==="
echo "    model=$VERTEX_MODEL  split=$SPLIT  limit=$LABEL_LIMIT  workers=$WORKERS"
date

nvidia-smi >> "$LOG" 2>&1 || echo "no GPU / driver (Gemini is API-only, so CPU VM is fine)"

export DEBIAN_FRONTEND=noninteractive
export PYTHONUNBUFFERED=1
export TQDM_MININTERVAL=10
echo "installing python deps (google-genai)..."
pip install --upgrade "google-genai>=0.3" >> "$LOG" 2>&1

# Vertex auth + config picked up from env by autolabel/label_vlm.py (no API key; VM SA).
PROJECT=$(curl -sf -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/project/project-id)
ZONE_PATH=$(curl -sf -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/zone)
REGION=$(echo "$ZONE_PATH" | awk -F/ '{print $NF}' | sed 's/-[a-z]$//')
export PROJECT_ID="$PROJECT"
export REGION="$REGION"
export VERTEX_MODEL="$VERTEX_MODEL"
echo "vertex: project=$PROJECT_ID region=$REGION model=$VERTEX_MODEL" | tee -a "$LOG"

# --- Fetch the code ------------------------------------------------------
echo "downloading repo code..."
cd "$RUN_DIR"
gsutil -q cp "$REPO_TARBALL" code.tar.gz >> "$LOG" 2>&1
tar -xzf code.tar.gz >> "$LOG" 2>&1   # extracts classification/ + autolabel/

# --- Pull the crops (single tarball — 100x faster than per-file rsync) ----
TARBALL="$BUCKET/crops/${SPLIT}_crops.tar"
if gsutil -q stat "$TARBALL" 2>/dev/null; then
  echo "downloading crops tarball $TARBALL ..."
  # Tarball has a top-level <split>/ dir; extract into crops/ so it lands at crops/<split>/.
  gsutil -q cp "$TARBALL" "$RUN_DIR/crops.tar" >> "$LOG" 2>&1
  tar -xf "$RUN_DIR/crops.tar" -C "$RUN_DIR/crops" >> "$LOG" 2>&1 && rm -f "$RUN_DIR/crops.tar"
else
  echo "no tarball; rsyncing crops from $BUCKET/crops/$SPLIT ..."
  gsutil -m rsync -r "$BUCKET/crops/$SPLIT" "$CROPS_DIR" >> "$LOG" 2>&1
fi
N_CROPS=$(find "$CROPS_DIR" -type f -name '*.jpg' | wc -l)
echo "$SPLIT crops on disk: $N_CROPS" | tee -a "$LOG"

LIMIT_FLAG=""
if [[ "$LABEL_LIMIT" != "0" ]]; then LIMIT_FLAG="--limit $LABEL_LIMIT"; fi

# --- Label with Gemini (resumable; sampled via --limit) ------------------
echo "=== Gemini labeling (output -> $LOG) ==="
# Resume across restarts: if a prior partial CSV exists in GCS, pull it first.
gsutil -q cp "$BUCKET/labels/$(basename "$OUT_CSV")" "$OUT_CSV" 2>/dev/null || true
# shellcheck disable=SC2086
python3 -m autolabel.label_vlm \
  --backend gemini \
  --crops "$CROPS_DIR" \
  --out "$OUT_CSV" \
  --workers "$WORKERS" \
  $LIMIT_FLAG \
  >> "$LOG" 2>&1
echo "=== Gemini done (exit $?) ==="
# The EXIT trap now syncs $OUT_DIR to GCS and deletes the VM.
