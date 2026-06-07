#!/bin/bash
# Local launcher — creates the GCP L4 GPU VM that fine-tunes YOLO on SKU-110K.
# Run from the repo root (or detection/). Requires: gcloud authenticated, PROJECT_ID set.
#
#   export PROJECT_ID=<your-project-id>
#   export ZONE=us-central1-a                           # optional (default below)
#   export BUCKET=gs://${PROJECT_ID}-sku110k-yolo       # optional (default below)
#   # Variant knobs (so a single launcher trains v8, v11, etc.):
#   export MODEL=yolov8m.pt                             # or yolo11m.pt, yolov9m.pt, ...
#   export TIME_HOURS=9.5                               # hard wall-clock cap
#   export VARIANT=v8                                   # subdir under $BUCKET/results/
#   bash detection/launch_vm.sh
#
# SECURITY POLICY: VMs in this project must NOT have an external/public IP.
#   - --no-address removes it.
#   - The VM reaches apt/pip/PyPI/CDN/GCS via Cloud NAT on the subnet (precheck below).
#   - SSH/monitoring goes through IAP tunnels (gcloud compute ssh --tunnel-through-iap).
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID (e.g. export PROJECT_ID=my-gcp-project)}"
ZONE="${ZONE:-us-central1-a}"
REGION="${ZONE%-*}"
BUCKET="${BUCKET:-gs://${PROJECT_ID}-sku110k-yolo}"

MODEL="${MODEL:-yolov8m.pt}"
TIME_HOURS="${TIME_HOURS:-9.5}"
VARIANT="${VARIANT:-v8}"
INSTANCE="${INSTANCE:-sku110k-train-${VARIANT}}"

# Default service account: project's compute SA. Surfaced (not implicit) so the
# bucket-IAM binding it needs is obvious. Caller can override via $SERVICE_ACCOUNT.
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"

# --- Precheck: subnet must have Cloud NAT ----------------------------------
# Without an external IP, apt-get / pip / public CDN downloads (yolo*.pt, SKU-110K)
# all need NAT. Private Google Access alone is not enough — it covers GCS + Google
# APIs but not Ubuntu repos or PyPI.
ROUTER="$(gcloud compute routers list --regions="$REGION" --format='value(name)' 2>/dev/null | head -1)"
NAT_FOUND=""
if [[ -n "$ROUTER" ]]; then
  NAT_FOUND="$(gcloud compute routers describe "$ROUTER" --region="$REGION" --format='value(nats[].name)' 2>/dev/null)"
fi
if [[ -z "$NAT_FOUND" ]]; then
  cat >&2 <<EOF
ERROR: no Cloud NAT found on any router in region '$REGION'.
       The no-public-IP VM will hang on apt-get / pip install / yolov*.pt download.

Enable Cloud NAT (one-time, ~10s) with:

  gcloud compute routers create nat-router-$REGION \\
    --region=$REGION --network=default
  gcloud compute routers nats create nat-config \\
    --router=nat-router-$REGION --region=$REGION \\
    --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges

Then re-run this script.
EOF
  exit 1
fi

# Resolve this script's dir so it works from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Render the startup script with all four placeholders.
STARTUP="$(mktemp)"
sed -e "s|__BUCKET__|${BUCKET}|g" \
    -e "s|__MODEL__|${MODEL}|g" \
    -e "s|__TIME_HOURS__|${TIME_HOURS}|g" \
    -e "s|__VARIANT__|${VARIANT}|g" \
    "$SCRIPT_DIR/train_sku110k.sh" > "$STARTUP"

cat <<EOF
Project        : $PROJECT_ID
Zone / Region  : $ZONE / $REGION
Bucket         : $BUCKET
Instance       : $INSTANCE
Service account: $SERVICE_ACCOUNT
Model          : $MODEL    (variant: $VARIANT, time cap: ${TIME_HOURS}h)
External IP    : NONE  (--no-address; egress via Cloud NAT)
EOF
echo "Creating L4 VM (g2-standard-8)..."

gcloud compute instances create "$INSTANCE" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --subnet=default \
  --no-address \
  --service-account="$SERVICE_ACCOUNT" \
  --machine-type=g2-standard-8 \
  --accelerator=type=nvidia-l4,count=1 \
  --maintenance-policy=TERMINATE \
  --restart-on-failure \
  --image-family=pytorch-2-9-cu129-ubuntu-2204-nvidia-580 \
  --image-project=deeplearning-platform-release \
  --boot-disk-size=200GB \
  --boot-disk-type=pd-ssd \
  --metadata="install-nvidia-driver=True" \
  --metadata-from-file=startup-script="$STARTUP" \
  --scopes=https://www.googleapis.com/auth/cloud-platform

rm -f "$STARTUP"

cat <<EOF

VM '$INSTANCE' is booting. Training begins automatically and the VM self-deletes when done.

Monitor (IAP tunnel — direct SSH is blocked because the VM has no external IP):
  gcloud compute ssh $INSTANCE --zone $ZONE --tunnel-through-iap \\
    --command "sudo tail -f /opt/runs/train.log"
  # or:  gcloud compute instances get-serial-port-output $INSTANCE --zone $ZONE

When the instance disappears from 'gcloud compute instances list', training is done.
Results:
  gsutil cat $BUCKET/results/$VARIANT/metrics.json
  gsutil -m cp -r $BUCKET/results/$VARIANT ./detection/artifacts/$VARIANT/
EOF
