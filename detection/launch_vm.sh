#!/bin/bash
# Local launcher — creates the GCP L4 GPU VM that trains YOLOv8m on SKU-110K.
# Run from the repo root (or detection/). Requires: gcloud authenticated, PROJECT_ID set.
#
#   export PROJECT_ID=<your-project-id>
#   export ZONE=us-central1-a               # optional (default below)
#   export BUCKET=gs://${PROJECT_ID}-sku110k-yolo   # optional (default below)
#   bash detection/launch_vm.sh
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID (e.g. export PROJECT_ID=my-gcp-project)}"
ZONE="${ZONE:-us-central1-a}"
BUCKET="${BUCKET:-gs://${PROJECT_ID}-sku110k-yolo}"
INSTANCE="${INSTANCE:-sku110k-train}"

# Resolve this script's dir so it works from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Inject the bucket into the startup script.
STARTUP="$(mktemp)"
sed "s|__BUCKET__|${BUCKET}|g" "$SCRIPT_DIR/train_sku110k.sh" > "$STARTUP"

echo "Project : $PROJECT_ID"
echo "Zone    : $ZONE"
echo "Bucket  : $BUCKET"
echo "Instance: $INSTANCE"
echo "Creating L4 VM (g2-standard-8)..."

gcloud compute instances create "$INSTANCE" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
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

Monitor:
  gcloud compute ssh $INSTANCE --zone $ZONE --command "tail -f /opt/runs/train.log"
  # or:  gcloud compute instances get-serial-port-output $INSTANCE --zone $ZONE

When the instance disappears from 'gcloud compute instances list', training is done.
Results:
  gsutil cat $BUCKET/results/metrics.json
  gsutil -m cp -r $BUCKET/results ./detection/
EOF
