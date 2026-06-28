#!/bin/bash
# VM startup script — runs as root on first boot. Generates per-product CROPS from SKU-110K
# shelf images using our trained detector, then uploads them to GCS. Inference-only, so this
# runs fine on a cheap GPU (T4) or even CPU.
#
# Mirrors detection/train_sku110k.sh's hard-won patterns:
#   - COST SAFETY: an EXIT trap ALWAYS syncs results to GCS and self-deletes the VM (3 layers).
#   - LOGGING: all heavy output goes DIRECTLY to a file (>> "$LOG" 2>&1), never through the GCP
#     metadata script-runner's stdout (its bufio.Scanner caps lines at 64KB; YOLO's \r progress
#     bars overflow it -> "token too long" -> the runner kills the child). Only short echoes go
#     to the console.
#
# Image: pytorch-2-9-cu129-ubuntu-2204-nvidia-580 (Deep Learning VM).
# Placeholders substituted by launch_crops.sh before upload:
#   __BUCKET__          training/results bucket (gs://...-sku110k-yolo) — crops land in $BUCKET/crops/
#   __DATASETS_BUCKET__ dataset cache bucket    (gs://...-datasets)     — SKU-110K tarball lives here
#   __WEIGHTS_URI__     gs:// path to the detector best.pt
#   __FRACTION__        train-image fraction (e.g. 0.10)
#   __REPO_TARBALL__    gs:// path to a tarball of the classification/ code (gen_crops.py etc.)
set -uo pipefail

BUCKET="__BUCKET__"
DATASETS_BUCKET="__DATASETS_BUCKET__"
WEIGHTS_URI="__WEIGHTS_URI__"
FRACTION="__FRACTION__"
REPO_TARBALL="__REPO_TARBALL__"

RUN_DIR=/opt/runs
LOG="$RUN_DIR/crops.log"
OUT_DIR="$RUN_DIR/crops"
mkdir -p "$RUN_DIR" "$OUT_DIR"
: > "$LOG"

# --- COST-SAFETY TRAP: always sync crops + self-delete on ANY exit ---------
cleanup() {
  rc=$?
  echo "=== cleanup (exit code $rc): syncing crops to GCS ==="
  gsutil -m rsync -r "$OUT_DIR" "$BUCKET/crops/" || echo "WARN: crops sync failed"
  gsutil cp "$LOG" "$BUCKET/crops/crops.log" || true

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

echo "=== retail-inventory-ai: SKU-110K crop generation STARTED ==="
echo "    weights=$WEIGHTS_URI  fraction=$FRACTION"
date

# GPU is optional here (inference). Wait briefly if a driver is present.
nvidia-smi >> "$LOG" 2>&1 || echo "no GPU / driver — running on CPU"

export DEBIAN_FRONTEND=noninteractive
echo "installing system libs (libgl1, libglib2.0-0)..."
apt-get update >> "$LOG" 2>&1 && apt-get install -y libgl1 libglib2.0-0 >> "$LOG" 2>&1
echo "installing ultralytics..."
pip install --upgrade "ultralytics>=8.2" >> "$LOG" 2>&1

export TQDM_MININTERVAL=10
export PYTHONUNBUFFERED=1

# --- Fetch the detector weights ------------------------------------------
echo "downloading detector weights..."
gsutil -q cp "$WEIGHTS_URI" "$RUN_DIR/best.pt" >> "$LOG" 2>&1

# --- Fetch + unpack the dataset cache (SKU-110K) -------------------------
echo "downloading + extracting SKU-110K from cache..."
mkdir -p /datasets && cd /datasets
gsutil -q cp "$DATASETS_BUCKET/sku110k/SKU110K_fixed.tar.gz" . >> "$LOG" 2>&1
tar -xzf SKU110K_fixed.tar.gz >> "$LOG" 2>&1 && rm SKU110K_fixed.tar.gz
# Resolve the images root (the tarball top dir varies: SKU110K_fixed/images or images/).
IMAGES_ROOT=$(find /datasets -type d -name images | head -1)
echo "images root: $IMAGES_ROOT" | tee -a "$LOG"

# --- Fetch our crop code -------------------------------------------------
echo "downloading repo code..."
cd "$RUN_DIR"
gsutil -q cp "$REPO_TARBALL" code.tar.gz >> "$LOG" 2>&1
tar -xzf code.tar.gz >> "$LOG" 2>&1   # extracts classification/ (gen_crops.py, taxonomy.py, ...)

# --- Generate crops ------------------------------------------------------
echo "=== generating crops (output -> $LOG) ==="
python3 -m classification.gen_crops \
  --weights "$RUN_DIR/best.pt" \
  --images-root "$IMAGES_ROOT" \
  --out "$OUT_DIR" \
  --fraction "$FRACTION" \
  >> "$LOG" 2>&1
echo "=== crop generation finished (exit $?) ==="
# The EXIT trap now syncs $OUT_DIR to GCS and deletes the VM.
