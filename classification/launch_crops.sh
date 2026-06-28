#!/bin/bash
# Local launcher — creates the GCP VM that crops SKU-110K shelf images with our detector.
# Run from the repo root (or classification/). Requires: gcloud authenticated, PROJECT_ID set.
#
#   export PROJECT_ID=<your-gcp-project-id>
#   export ZONE=us-central1-a                               # optional
#   export BUCKET=gs://${PROJECT_ID}-sku110k-yolo           # optional (crops land in $BUCKET/crops/)
#   export DATASETS_BUCKET=gs://${PROJECT_ID}-datasets      # optional (SKU-110K cache)
#   export WEIGHTS_URI=gs://${PROJECT_ID}-sku110k-yolo/results/v11/sku110k/weights/best.pt  # optional
#   export FRACTION=0.10                                    # optional (train fraction)
#   export MACHINE_TYPE=g2-standard-8 ACCELERATOR=type=nvidia-l4,count=1   # optional GPU
#   # or CPU-only:  export MACHINE_TYPE=e2-standard-8 ACCELERATOR=""
#   bash classification/launch_crops.sh
#
# Same security policy as detection: NO external IP (--no-address); egress via Cloud NAT;
# SSH/monitoring via IAP. The VM self-deletes when cropping finishes (3-layer trap in the
# startup script). Inference-only, so CPU or a single cheap GPU is plenty.
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID (e.g. export PROJECT_ID=my-gcp-project)}"
ZONE="${ZONE:-us-central1-a}"
REGION="${ZONE%-*}"
BUCKET="${BUCKET:-gs://${PROJECT_ID}-sku110k-yolo}"
DATASETS_BUCKET="${DATASETS_BUCKET:-gs://${PROJECT_ID}-datasets}"
WEIGHTS_URI="${WEIGHTS_URI:-${BUCKET}/results/v11/sku110k/weights/best.pt}"
FRACTION="${FRACTION:-0.10}"

# Default to a single L4 (fast); override to CPU with MACHINE_TYPE=e2-standard-8 ACCELERATOR="".
MACHINE_TYPE="${MACHINE_TYPE:-g2-standard-8}"
ACCELERATOR="${ACCELERATOR-type=nvidia-l4,count=1}"
INSTANCE="${INSTANCE:-sku110k-crops}"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"

# --- Precheck: subnet must have Cloud NAT (no-public-IP VM needs it for apt/pip) ---
ROUTER="$(gcloud compute routers list --regions="$REGION" --format='value(name)' 2>/dev/null | head -1)"
NAT_FOUND=""
if [[ -n "$ROUTER" ]]; then
  NAT_FOUND="$(gcloud compute routers describe "$ROUTER" --region="$REGION" --format='value(nats[].name)' 2>/dev/null)"
fi
if [[ -z "$NAT_FOUND" ]]; then
  cat >&2 <<EOF
ERROR: no Cloud NAT found on any router in region '$REGION'.
       The no-public-IP VM will hang on apt-get / pip install.

  gcloud compute routers create nat-router-$REGION --region=$REGION --network=default
  gcloud compute routers nats create nat-config --router=nat-router-$REGION \\
    --region=$REGION --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
EOF
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Package the classification/ code and stage it in GCS ----------------
# The VM downloads + extracts this to get gen_crops.py + taxonomy.py.
echo "Packaging classification/ code and uploading to $BUCKET/code/ ..."
CODE_TARBALL="$(mktemp -t classcode.XXXXXX.tar.gz)"
tar -czf "$CODE_TARBALL" -C "$REPO_ROOT" classification
REPO_TARBALL="${BUCKET}/code/classification.tar.gz"
gsutil -q cp "$CODE_TARBALL" "$REPO_TARBALL"
rm -f "$CODE_TARBALL"

# --- Render the startup script with placeholders -------------------------
STARTUP="$(mktemp)"
sed -e "s|__BUCKET__|${BUCKET}|g" \
    -e "s|__DATASETS_BUCKET__|${DATASETS_BUCKET}|g" \
    -e "s|__WEIGHTS_URI__|${WEIGHTS_URI}|g" \
    -e "s|__FRACTION__|${FRACTION}|g" \
    -e "s|__REPO_TARBALL__|${REPO_TARBALL}|g" \
    "$SCRIPT_DIR/crop_sku110k.sh" > "$STARTUP"

# Build the create command (GPU accelerator flags only when ACCELERATOR is set).
ACCEL_FLAGS=()
if [[ -n "$ACCELERATOR" ]]; then
  ACCEL_FLAGS=(--accelerator="$ACCELERATOR" --maintenance-policy=TERMINATE --metadata=install-nvidia-driver=True)
fi

cat <<EOF
Project        : $PROJECT_ID
Zone / Region  : $ZONE / $REGION
Bucket (crops) : $BUCKET/crops/
Datasets cache : $DATASETS_BUCKET
Weights        : $WEIGHTS_URI
Fraction       : $FRACTION (train; val/test always full)
Instance       : $INSTANCE
Machine        : $MACHINE_TYPE   accelerator: ${ACCELERATOR:-none}
External IP    : NONE  (--no-address; egress via Cloud NAT)
EOF
echo "Creating crop VM..."

# shellcheck disable=SC2086
gcloud compute instances create "$INSTANCE" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --subnet=default \
  --no-address \
  --service-account="$SERVICE_ACCOUNT" \
  --machine-type="$MACHINE_TYPE" \
  "${ACCEL_FLAGS[@]}" \
  --image-family=pytorch-2-9-cu129-ubuntu-2204-nvidia-580 \
  --image-project=deeplearning-platform-release \
  --boot-disk-size=200GB \
  --boot-disk-type=pd-ssd \
  --metadata-from-file=startup-script="$STARTUP" \
  --scopes=https://www.googleapis.com/auth/cloud-platform

rm -f "$STARTUP"

cat <<EOF

VM '$INSTANCE' is booting. Cropping begins automatically; the VM self-deletes when done.

Monitor (IAP tunnel — direct SSH is blocked because the VM has no external IP):
  gcloud compute ssh $INSTANCE --zone $ZONE --tunnel-through-iap --command "sudo tail -f /opt/runs/crops.log"

When the instance disappears from 'gcloud compute instances list', cropping is done. Then:
  gsutil ls $BUCKET/crops/
  gsutil -m cp -r $BUCKET/crops ./data/crops      # pull locally for labeling/training
EOF
