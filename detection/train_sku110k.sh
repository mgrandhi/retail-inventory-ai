#!/bin/bash
# VM startup script — runs as root on first boot of the GCP L4 instance.
# Trains YOLOv8m on SKU-110K, validates, extracts metrics, syncs to GCS.
#
# COST SAFETY: a trap on EXIT ALWAYS syncs artifacts to GCS and self-deletes the VM,
# whether training succeeds, fails, or errors out — so a crash never leaves an idle GPU running.
#
# LOGGING: all training output goes DIRECTLY to a log file (>> "$LOG" 2>&1), NOT through the GCP
# metadata script-runner's stdout. YOLO's progress bars use \r and produce multi-KB "lines" that
# overflow the runner's bufio.Scanner (64KB) → "token too long" → it kills the child process.
# Writing to a file avoids the scanner entirely. Only short milestone echoes reach the console.
#
# Image: pytorch-2-9-cu129-ubuntu-2204-nvidia-580 (Deep Learning VM) — CUDA/driver preinstalled.
# __BUCKET__ is substituted by launch_vm.sh before upload.
set -uo pipefail

BUCKET="__BUCKET__"
RUN_DIR=/opt/runs
LOG="$RUN_DIR/train.log"
mkdir -p "$RUN_DIR"
: > "$LOG"

# --- COST-SAFETY TRAP: always sync + self-delete on ANY exit ---------------
cleanup() {
  rc=$?
  echo "=== cleanup (exit code $rc): syncing results to GCS, then deleting VM ==="
  gsutil -m rsync -r "$RUN_DIR" "$BUCKET/results/" || echo "WARN: gsutil sync failed"
  NAME=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/name)
  ZONE=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
  echo "=== deleting self: $NAME in $ZONE ==="
  gcloud compute instances delete "$NAME" --zone "$ZONE" --quiet
}
trap cleanup EXIT

echo "=== retail-inventory-ai: SKU-110K detection training STARTED ==="
date

# NVIDIA driver is preinstalled on the DLVM — wait until it's ready (short, safe to console).
until nvidia-smi >> "$LOG" 2>&1; do echo "waiting for GPU driver..."; sleep 15; done
echo "GPU ready."

# OpenCV (an Ultralytics dependency) needs system OpenGL libs not in the base image.
export DEBIAN_FRONTEND=noninteractive
echo "installing system libs (libgl1, libglib2.0-0)..."
apt-get update >> "$LOG" 2>&1 && apt-get install -y libgl1 libglib2.0-0 >> "$LOG" 2>&1

echo "installing ultralytics..."
pip install --upgrade "ultralytics>=8.2" >> "$LOG" 2>&1

# Quieter, non-interactive progress output (smaller log, no rich/tqdm control-char spam).
export TQDM_MININTERVAL=10        # update progress bars at most every 10s
export PYTHONUNBUFFERED=1

# --- Train ---------------------------------------------------------------
# All output to the log file; only the final status reaches the console.
# time=9.5  -> HARD 9.5h wall-clock cap (auto-scales epochs, auto-stops cleanly).
# epochs=50 -> upper bound only; the time cap usually stops first.
# batch=-1  -> auto-batch (~60% VRAM); fits the L4's 24 GB at imgsz=1280.
echo "=== starting YOLOv8m training (output -> $LOG) ==="
yolo detect train \
  model=yolov8m.pt \
  data=SKU-110K.yaml \
  epochs=50 \
  time=9.5 \
  imgsz=1280 \
  batch=-1 \
  cos_lr=True \
  project="$RUN_DIR" \
  name=sku110k \
  exist_ok=True \
  >> "$LOG" 2>&1
echo "=== training finished (exit $?) ==="

# --- Final validation (the two target metrics) ---------------------------
echo "=== running final validation ==="
yolo detect val \
  model="$RUN_DIR/sku110k/weights/best.pt" \
  data=SKU-110K.yaml \
  imgsz=1280 \
  project="$RUN_DIR" \
  name=sku110k_val \
  exist_ok=True \
  >> "$LOG" 2>&1

# --- Extract mAP@0.5 and mAP@0.5:0.95 into a clean metrics.json -----------
# Guarded with `|| true` so a parse hiccup can't skip the cleanup trap.
python3 - "$RUN_DIR" >> "$LOG" 2>&1 <<'PY' || true
import csv, json, os, sys
rd = sys.argv[1]
csvf = os.path.join(rd, "sku110k", "results.csv")
rows = [r for r in csv.DictReader(open(csvf)) if r.get("metrics/mAP50(B)", "").strip()]
last = rows[-1]
out = {
    "mAP_50":    round(float(last["metrics/mAP50(B)"]), 4),
    "mAP_50_95": round(float(last["metrics/mAP50-95(B)"]), 4),
    "precision": round(float(last["metrics/precision(B)"]), 4),
    "recall":    round(float(last["metrics/recall(B)"]), 4),
    "epoch":     int(float(last["epoch"])),
}
json.dump(out, open(os.path.join(rd, "metrics.json"), "w"), indent=2)
print(json.dumps(out, indent=2))
PY

echo "=== training + validation complete; metrics.json written ==="
# The EXIT trap now syncs to GCS and deletes the VM.
