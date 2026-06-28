#!/bin/bash
# Local launcher — creates a cheap CPU VM that runs the confidence-gate threshold sweep
# (classification.infer --tune-threshold) on the trained classifier over the held-out val crops.
# Run from the repo root (or classification/).
#
#   export PROJECT_ID=<your-gcp-project-id>
#   export ZONE=us-central1-a                               # optional
#   export BUCKET=gs://${PROJECT_ID}-sku110k-yolo           # optional
#   export VARIANT=clip_v1                                  # classifier subdir under $BUCKET/classifier/
#   export SPLIT=val                                        # crops to evaluate on
#   export TRUTH=gs://.../labels_gemini_val.csv             # ground-truth labels CSV (our own val labels)
#   bash classification/launch_tune_gate.sh
#
# NO external IP (--no-address); Cloud NAT egress; self-deletes when the sweep finishes.
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
ZONE="${ZONE:-us-central1-a}"
REGION="${ZONE%-*}"
BUCKET="${BUCKET:-gs://${PROJECT_ID}-sku110k-yolo}"
VARIANT="${VARIANT:-clip_v1}"
SPLIT="${SPLIT:-val}"
TRUTH="${TRUTH:-${BUCKET}/labels/labels_gemini_${SPLIT}.csv}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-8}"
INSTANCE="${INSTANCE:-clf-gate-$(echo "$VARIANT" | tr '_' '-')}"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"

# --- Precheck: Cloud NAT (no-public-IP VM needs it) ----------------------
ROUTER="$(gcloud compute routers list --regions="$REGION" --format='value(name)' 2>/dev/null | head -1)"
NAT_FOUND=""
if [[ -n "$ROUTER" ]]; then
  NAT_FOUND="$(gcloud compute routers describe "$ROUTER" --region="$REGION" --format='value(nats[].name)' 2>/dev/null)"
fi
if [[ -z "$NAT_FOUND" ]]; then
  echo "ERROR: no Cloud NAT in region '$REGION'. Create it and retry." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Packaging code (classification/ + autolabel/) -> $BUCKET/code/ ..."
CODE_TARBALL="$(mktemp -t gatecode.XXXXXX.tar.gz)"
tar -czf "$CODE_TARBALL" -C "$REPO_ROOT" classification autolabel
REPO_TARBALL="${BUCKET}/code/gate_code.tar.gz"
gsutil -q cp "$CODE_TARBALL" "$REPO_TARBALL"
rm -f "$CODE_TARBALL"

STARTUP="$(mktemp)"
sed -e "s|__BUCKET__|${BUCKET}|g" \
    -e "s|__REPO_TARBALL__|${REPO_TARBALL}|g" \
    -e "s|__VARIANT__|${VARIANT}|g" \
    -e "s|__SPLIT__|${SPLIT}|g" \
    -e "s|__TRUTH_URI__|${TRUTH}|g" \
    "$SCRIPT_DIR/tune_gate.sh" > "$STARTUP"

cat <<EOF
Project        : $PROJECT_ID
Zone / Region  : $ZONE / $REGION
Variant        : $VARIANT   (model at $BUCKET/classifier/$VARIANT/)
Eval split     : $SPLIT     (crops $BUCKET/crops/${SPLIT}_crops.tar)
Truth labels   : $TRUTH
Output         : $BUCKET/classifier/$VARIANT/gate_sweep.json (+ gate.log)
Instance       : $INSTANCE   ($MACHINE_TYPE, CPU-only)
External IP    : NONE  (--no-address; egress via Cloud NAT)
EOF
echo "Creating gate-sweep VM..."

gcloud compute instances create "$INSTANCE" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --subnet=default \
  --no-address \
  --service-account="$SERVICE_ACCOUNT" \
  --machine-type="$MACHINE_TYPE" \
  --image-family=pytorch-2-9-cu129-ubuntu-2204-nvidia-580 \
  --image-project=deeplearning-platform-release \
  --boot-disk-size=100GB \
  --boot-disk-type=pd-ssd \
  --metadata-from-file=startup-script="$STARTUP" \
  --scopes=https://www.googleapis.com/auth/cloud-platform

rm -f "$STARTUP"

cat <<EOF

VM '$INSTANCE' is booting. Sweep runs automatically; the VM self-deletes when done.
Results: gsutil cat $BUCKET/classifier/$VARIANT/gate.log
         gsutil cat $BUCKET/classifier/$VARIANT/gate_sweep.json
EOF
