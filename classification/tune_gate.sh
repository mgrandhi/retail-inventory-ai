#!/bin/bash
# VM startup script — runs the confidence-gate threshold sweep (classification.infer
# --tune-threshold) on the trained classifier over the held-out val crops, writes the sweep
# JSON + a human-readable table to GCS, then self-deletes. CPU-only (CLIP inference over a few
# thousand crops is fast enough on CPU; no GPU needed).
#
# Mirrors the hard-won VM patterns: 3-layer self-delete EXIT trap, log-to-file (not the metadata
# runner's 64KB-capped stdout), crop pull from the single tarball.
# Placeholders substituted by launch_tune_gate.sh:
#   __BUCKET__       results bucket (model at $BUCKET/classifier/$VARIANT/, crops at $BUCKET/crops/).
#   __REPO_TARBALL__ gs:// tarball of classification/ + autolabel/ code.
#   __VARIANT__      classifier subdir (e.g. clip_v1).
#   __SPLIT__        which crops to evaluate on (val).
#   __TRUTH_URI__    gs:// path to the ground-truth labels CSV (our own labels_gemini_val.csv).
set -uo pipefail

BUCKET="__BUCKET__"
REPO_TARBALL="__REPO_TARBALL__"
VARIANT="__VARIANT__"
SPLIT="__SPLIT__"
TRUTH_URI="__TRUTH_URI__"

RUN_DIR=/opt/runs
LOG="$RUN_DIR/gate.log"
MODEL_DIR="$RUN_DIR/model"
OUT_DIR="$RUN_DIR/out"
mkdir -p "$RUN_DIR" "$MODEL_DIR" "$OUT_DIR" "$RUN_DIR/crops"
: > "$LOG"

cleanup() {
  rc=$?
  echo "=== cleanup (exit $rc): syncing gate sweep to GCS ==="
  gsutil -m rsync -r "$OUT_DIR" "$BUCKET/classifier/$VARIANT/" || echo "WARN: sync failed"
  gsutil cp "$LOG" "$BUCKET/classifier/$VARIANT/gate.log" || true

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

echo "=== retail-inventory-ai: confidence-gate sweep STARTED (variant=$VARIANT split=$SPLIT) ==="
date
export DEBIAN_FRONTEND=noninteractive
export PYTHONUNBUFFERED=1
export TQDM_MININTERVAL=10
apt-get update >> "$LOG" 2>&1 && apt-get install -y libgl1 libglib2.0-0 >> "$LOG" 2>&1
echo "installing python deps..."
pip install --upgrade "open-clip-torch>=2.24" "scikit-learn>=1.4" torchvision >> "$LOG" 2>&1

cd "$RUN_DIR"
echo "downloading repo code..."
gsutil -q cp "$REPO_TARBALL" code.tar.gz >> "$LOG" 2>&1
tar -xzf code.tar.gz >> "$LOG" 2>&1   # classification/ + autolabel/

echo "downloading model ($VARIANT) + truth labels..."
gsutil -q cp "$BUCKET/classifier/$VARIANT/classifier.pt"   "$MODEL_DIR/classifier.pt"   >> "$LOG" 2>&1
gsutil -q cp "$BUCKET/classifier/$VARIANT/label_maps.json" "$MODEL_DIR/label_maps.json" >> "$LOG" 2>&1
gsutil -q cp "$TRUTH_URI" "$RUN_DIR/truth.csv" >> "$LOG" 2>&1

echo "downloading $SPLIT crops (single tarball)..."
if gsutil -q stat "$BUCKET/crops/${SPLIT}_crops.tar" 2>/dev/null; then
  gsutil -q cp "$BUCKET/crops/${SPLIT}_crops.tar" "$RUN_DIR/crops.tar" >> "$LOG" 2>&1
  tar -xf "$RUN_DIR/crops.tar" -C "$RUN_DIR/crops" >> "$LOG" 2>&1 && rm -f "$RUN_DIR/crops.tar"
else
  gsutil -m -q cp -r "$BUCKET/crops/$SPLIT" "$RUN_DIR/crops/" >> "$LOG" 2>&1
fi
echo "$SPLIT crops on disk: $(find "$RUN_DIR/crops/$SPLIT" -name '*.jpg'|wc -l)" | tee -a "$LOG"

echo "=== threshold sweep (output -> $LOG) ==="
python3 -m classification.infer \
  --tune-threshold \
  --model-dir "$MODEL_DIR" \
  --crops "$RUN_DIR/crops/$SPLIT" \
  --truth "$RUN_DIR/truth.csv" \
  --out "$OUT_DIR/gate_sweep.json" \
  --device cpu \
  2>&1 | tee -a "$LOG"
echo "=== gate sweep finished (exit $?) ==="
# The EXIT trap syncs $OUT_DIR (gate_sweep.json) to GCS and deletes the VM.
