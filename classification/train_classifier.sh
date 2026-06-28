#!/bin/bash
# VM startup script — trains the two-head crop classifier on GCP, then syncs artifacts to GCS.
# Mirrors detection/train_sku110k.sh's patterns: 3-layer self-delete trap, log-to-file (never
# through the metadata script-runner's 64KB-capped stdout), dataset pull from the cache bucket.
#
# Image: pytorch-2-9-cu129-ubuntu-2204-nvidia-580 (Deep Learning VM).
# Placeholders substituted by launch_train.sh:
#   __BUCKET__        results bucket — crops live in $BUCKET/crops/, classifier lands in $BUCKET/classifier/$VARIANT/
#   __REPO_TARBALL__  gs:// tarball of classification/ + autolabel/ code
#   __TRAIN_LABELS__  gs:// path to the train labels CSV
#   __VAL_LABELS__    gs:// path to the val (ground-truth) labels CSV
#   __BACKBONE__      clip | resnet50
#   __VARIANT__       subdir under $BUCKET/classifier/ (e.g. clip_v1)
#   __EPOCHS__        training epochs
set -uo pipefail

BUCKET="__BUCKET__"
REPO_TARBALL="__REPO_TARBALL__"
TRAIN_LABELS_URI="__TRAIN_LABELS__"
VAL_LABELS_URI="__VAL_LABELS__"
BACKBONE="__BACKBONE__"
VARIANT="__VARIANT__"
EPOCHS="__EPOCHS__"

RUN_DIR=/opt/runs
LOG="$RUN_DIR/train.log"
OUT_DIR="$RUN_DIR/artifacts"
mkdir -p "$RUN_DIR" "$OUT_DIR"
: > "$LOG"

cleanup() {
  rc=$?
  echo "=== cleanup (exit code $rc): syncing classifier artifacts to GCS ==="
  gsutil -m rsync -r "$OUT_DIR" "$BUCKET/classifier/$VARIANT/" || echo "WARN: artifact sync failed"
  gsutil cp "$LOG" "$BUCKET/classifier/$VARIANT/train.log" || true

  NAME=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
  ZONE_PATH=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone)
  ZONE=$(echo "$ZONE_PATH" | awk -F/ '{print $NF}')
  PROJECT=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
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

echo "=== retail-inventory-ai: classifier training STARTED (backbone=$BACKBONE variant=$VARIANT) ==="
date
until nvidia-smi >> "$LOG" 2>&1; do echo "waiting for GPU driver..."; sleep 15; done
echo "GPU ready."

export DEBIAN_FRONTEND=noninteractive
apt-get update >> "$LOG" 2>&1 && apt-get install -y libgl1 libglib2.0-0 >> "$LOG" 2>&1
echo "installing python deps..."
pip install --upgrade "open-clip-torch>=2.24" "scikit-learn>=1.4" torchvision >> "$LOG" 2>&1

export TQDM_MININTERVAL=10
export PYTHONUNBUFFERED=1

# --- Fetch code + crops + labels -----------------------------------------
cd "$RUN_DIR"
echo "downloading repo code..."
gsutil -q cp "$REPO_TARBALL" code.tar.gz >> "$LOG" 2>&1
tar -xzf code.tar.gz >> "$LOG" 2>&1   # classification/ + autolabel/

echo "downloading crops (single tarballs — 100x faster than per-file cp on 100k+ tiny files)..."
mkdir -p data/crops
for split in train val; do
  if gsutil -q stat "$BUCKET/crops/${split}_crops.tar" 2>/dev/null; then
    gsutil -q cp "$BUCKET/crops/${split}_crops.tar" "$RUN_DIR/${split}_crops.tar" >> "$LOG" 2>&1
    tar -xf "$RUN_DIR/${split}_crops.tar" -C data/crops >> "$LOG" 2>&1 && rm -f "$RUN_DIR/${split}_crops.tar"
  else
    echo "no ${split}_crops.tar; falling back to per-file cp" >> "$LOG"
    gsutil -m -q cp -r "$BUCKET/crops/$split" data/crops/ >> "$LOG" 2>&1
  fi
done
echo "train crops: $(find data/crops/train -name '*.jpg'|wc -l)  val crops: $(find data/crops/val -name '*.jpg'|wc -l)" | tee -a "$LOG"

echo "downloading labels..."
gsutil -q cp "$TRAIN_LABELS_URI" train_labels.csv >> "$LOG" 2>&1
gsutil -q cp "$VAL_LABELS_URI"   val_labels.csv   >> "$LOG" 2>&1

# --- Train ---------------------------------------------------------------
echo "=== training (output -> $LOG) ==="
python3 -m classification.train_classifier \
  --backbone "$BACKBONE" \
  --train-labels train_labels.csv --train-crops data/crops/train \
  --val-labels val_labels.csv --val-crops data/crops/val \
  --out "$OUT_DIR" \
  --epochs "$EPOCHS" \
  >> "$LOG" 2>&1
echo "=== training finished (exit $?) ==="
# The EXIT trap now syncs $OUT_DIR to GCS and deletes the VM.
