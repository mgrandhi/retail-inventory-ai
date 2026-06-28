#!/bin/bash
# Local launcher — creates the GCP L4 VM that trains the two-head crop classifier.
# Run from the repo root (or classification/). Requires: gcloud authenticated, PROJECT_ID set.
#
#   export PROJECT_ID=<your-gcp-project-id>
#   export ZONE=us-central1-a                               # optional
#   export BUCKET=gs://${PROJECT_ID}-sku110k-yolo           # optional (crops + classifier live here)
#   export TRAIN_LABELS=gs://.../labels_train.csv           # required: train labels CSV in GCS
#   export VAL_LABELS=gs://.../product_labels_openai_val_normalized_categories.csv  # required: val ground truth
#   export BACKBONE=clip                                    # clip | resnet50
#   export VARIANT=clip_v1                                  # subdir under $BUCKET/classifier/
#   export EPOCHS=15
#   bash classification/launch_train.sh
#
# Same security policy as detection: NO external IP; Cloud NAT egress; IAP for SSH. Self-deletes.
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
: "${TRAIN_LABELS:?set TRAIN_LABELS (gs:// path to the train labels CSV)}"
: "${VAL_LABELS:?set VAL_LABELS (gs:// path to the val ground-truth CSV)}"
ZONE="${ZONE:-us-central1-a}"
REGION="${ZONE%-*}"
BUCKET="${BUCKET:-gs://${PROJECT_ID}-sku110k-yolo}"
BACKBONE="${BACKBONE:-clip}"
VARIANT="${VARIANT:-${BACKBONE}_v1}"
EPOCHS="${EPOCHS:-15}"
# GCE instance names can't contain '_' (must match [a-z]([-a-z0-9]*[a-z0-9])?); VARIANT (e.g.
# clip_v1) is a valid GCS path but not a valid hostname — sanitize underscores to hyphens.
INSTANCE="${INSTANCE:-clf-train-$(echo "$VARIANT" | tr '_' '-')}"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"

# --- Precheck: Cloud NAT (no-public-IP VM needs it) ----------------------
ROUTER="$(gcloud compute routers list --regions="$REGION" --format='value(name)' 2>/dev/null | head -1)"
NAT_FOUND=""
if [[ -n "$ROUTER" ]]; then
  NAT_FOUND="$(gcloud compute routers describe "$ROUTER" --region="$REGION" --format='value(nats[].name)' 2>/dev/null)"
fi
if [[ -z "$NAT_FOUND" ]]; then
  echo "ERROR: no Cloud NAT in region '$REGION'. Create it (see detection/launch_vm.sh) and retry." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Packaging code (classification/ + autolabel/) -> $BUCKET/code/ ..."
CODE_TARBALL="$(mktemp -t clftcode.XXXXXX.tar.gz)"
tar -czf "$CODE_TARBALL" -C "$REPO_ROOT" classification autolabel
REPO_TARBALL="${BUCKET}/code/classification.tar.gz"
gsutil -q cp "$CODE_TARBALL" "$REPO_TARBALL"
rm -f "$CODE_TARBALL"

STARTUP="$(mktemp)"
sed -e "s|__BUCKET__|${BUCKET}|g" \
    -e "s|__REPO_TARBALL__|${REPO_TARBALL}|g" \
    -e "s|__TRAIN_LABELS__|${TRAIN_LABELS}|g" \
    -e "s|__VAL_LABELS__|${VAL_LABELS}|g" \
    -e "s|__BACKBONE__|${BACKBONE}|g" \
    -e "s|__VARIANT__|${VARIANT}|g" \
    -e "s|__EPOCHS__|${EPOCHS}|g" \
    "$SCRIPT_DIR/train_classifier.sh" > "$STARTUP"

cat <<EOF
Project        : $PROJECT_ID
Zone / Region  : $ZONE / $REGION
Bucket         : $BUCKET   (classifier -> $BUCKET/classifier/$VARIANT/)
Train labels   : $TRAIN_LABELS
Val labels     : $VAL_LABELS
Backbone       : $BACKBONE   variant: $VARIANT   epochs: $EPOCHS
Instance       : $INSTANCE
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
  --image-family=pytorch-2-9-cu129-ubuntu-2204-nvidia-580 \
  --image-project=deeplearning-platform-release \
  --boot-disk-size=200GB \
  --boot-disk-type=pd-ssd \
  --metadata=install-nvidia-driver=True \
  --metadata-from-file=startup-script="$STARTUP" \
  --scopes=https://www.googleapis.com/auth/cloud-platform

rm -f "$STARTUP"

cat <<EOF

VM '$INSTANCE' is booting. Training begins automatically; the VM self-deletes when done.

Monitor:
  gcloud compute ssh $INSTANCE --zone $ZONE --tunnel-through-iap --command "sudo tail -f /opt/runs/train.log"

Results when done:
  gsutil cat $BUCKET/classifier/$VARIANT/metrics.json
  gsutil -m cp -r $BUCKET/classifier/$VARIANT ./classification/artifacts/$VARIANT
EOF
