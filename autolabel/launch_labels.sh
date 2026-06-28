#!/bin/bash
# Local launcher — creates the GCP VM that labels one SPLIT's crops with the Vertex Gemini VLM
# (chosen over CLIP by the 2026-06-27 decision gate). Output is the teacher-label CSV the
# classifier trains on. Run from the repo root (or autolabel/).
#
#   export PROJECT_ID=<your-gcp-project-id>
#   export ZONE=us-central1-a                          # optional
#   export BUCKET=gs://${PROJECT_ID}-sku110k-yolo      # optional (crops in $BUCKET/crops/<split>_crops.tar)
#   export SPLIT=train                                 # optional (train|val|test; default train)
#   export VERTEX_MODEL=gemini-2.5-flash               # optional (gemini-2.5-flash-lite = cheaper)
#   export LABEL_LIMIT=30000                           # optional (crops Gemini labels; 0=all)
#   export WORKERS=32                                  # optional (Gemini concurrency)
#   bash autolabel/launch_labels.sh
#
# PREREQ (one-time, needs an owner — auto-tooling can't self-grant project IAM):
#   gcloud services enable aiplatform.googleapis.com --project=$PROJECT_ID         # DONE 2026-06-27
#   gcloud projects add-iam-policy-binding $PROJECT_ID \
#     --member="serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
#     --role="roles/aiplatform.user" --condition=None                             # DONE 2026-06-27
#
# Same security policy as detection/crops: NO external IP (--no-address); egress via Cloud NAT;
# SSH/monitoring via IAP. The VM self-deletes when labeling finishes (3-layer trap).
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID (e.g. export PROJECT_ID=my-gcp-project)}"
ZONE="${ZONE:-us-central1-a}"
REGION="${ZONE%-*}"
BUCKET="${BUCKET:-gs://${PROJECT_ID}-sku110k-yolo}"
SPLIT="${SPLIT:-train}"
VERTEX_MODEL="${VERTEX_MODEL:-gemini-2.5-flash}"
LABEL_LIMIT="${LABEL_LIMIT:-30000}"
WORKERS="${WORKERS:-32}"

# Gemini is API-only (no local model), so this needs NO GPU — a cheap CPU VM is plenty and the
# many-worker throughput is bound by the Vertex endpoint, not local compute.
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-8}"
ACCELERATOR="${ACCELERATOR-}"
INSTANCE="${INSTANCE:-sku110k-labels-${SPLIT}}"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"

# --- Precheck: Vertex IAM on the VM service account (gemini backend needs it) ---
HAS_AIP="$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:${SERVICE_ACCOUNT} AND bindings.role:roles/aiplatform.user" \
  --format='value(bindings.role)' 2>/dev/null | head -1)"
if [[ -z "$HAS_AIP" ]]; then
  cat >&2 <<EOF
ERROR: service account $SERVICE_ACCOUNT lacks roles/aiplatform.user.
       The Gemini backend will 403. Grant it (needs a project owner), then re-run:

  gcloud projects add-iam-policy-binding $PROJECT_ID \\
    --member="serviceAccount:${SERVICE_ACCOUNT}" \\
    --role="roles/aiplatform.user" --condition=None
EOF
  exit 1
fi

# --- Precheck: subnet must have Cloud NAT (no-public-IP VM needs it for apt/pip) ---
ROUTER="$(gcloud compute routers list --regions="$REGION" --format='value(name)' 2>/dev/null | head -1)"
NAT_FOUND=""
if [[ -n "$ROUTER" ]]; then
  NAT_FOUND="$(gcloud compute routers describe "$ROUTER" --region="$REGION" --format='value(nats[].name)' 2>/dev/null)"
fi
if [[ -z "$NAT_FOUND" ]]; then
  echo "ERROR: no Cloud NAT on any router in region '$REGION'; no-public-IP VM will hang on apt/pip." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Package classification/ + autolabel/ code and stage in GCS ----------
echo "Packaging code (classification/ + autolabel/) and uploading to $BUCKET/code/ ..."
CODE_TARBALL="$(mktemp -t labelcode.XXXXXX.tar.gz)"
tar -czf "$CODE_TARBALL" -C "$REPO_ROOT" classification autolabel
REPO_TARBALL="${BUCKET}/code/label_code.tar.gz"
gsutil -q cp "$CODE_TARBALL" "$REPO_TARBALL"
rm -f "$CODE_TARBALL"

# --- Render the startup script with placeholders -------------------------
STARTUP="$(mktemp)"
sed -e "s|__BUCKET__|${BUCKET}|g" \
    -e "s|__REPO_TARBALL__|${REPO_TARBALL}|g" \
    -e "s|__SPLIT__|${SPLIT}|g" \
    -e "s|__LABEL_LIMIT__|${LABEL_LIMIT}|g" \
    -e "s|__VERTEX_MODEL__|${VERTEX_MODEL}|g" \
    -e "s|__WORKERS__|${WORKERS}|g" \
    "$SCRIPT_DIR/label_sku110k.sh" > "$STARTUP"

ACCEL_FLAGS=()
if [[ -n "$ACCELERATOR" ]]; then
  ACCEL_FLAGS=(--accelerator="$ACCELERATOR" --maintenance-policy=TERMINATE --metadata=install-nvidia-driver=True)
fi

cat <<EOF
Project        : $PROJECT_ID
Zone / Region  : $ZONE / $REGION
Split / crops  : $SPLIT   ($BUCKET/crops/${SPLIT}_crops.tar)
Labels (out)   : $BUCKET/labels/labels_gemini_${SPLIT}.csv
Vertex model   : $VERTEX_MODEL   (Gemini labels $LABEL_LIMIT crops, $WORKERS workers)
Instance       : $INSTANCE
Machine        : $MACHINE_TYPE   accelerator: ${ACCELERATOR:-none}
External IP    : NONE  (--no-address; egress via Cloud NAT)
EOF
echo "Creating labeling VM..."

# shellcheck disable=SC2086
gcloud compute instances create "$INSTANCE" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --subnet=default \
  --no-address \
  --service-account="$SERVICE_ACCOUNT" \
  --machine-type="$MACHINE_TYPE" \
  ${ACCEL_FLAGS[@]+"${ACCEL_FLAGS[@]}"} \
  --image-family=pytorch-2-9-cu129-ubuntu-2204-nvidia-580 \
  --image-project=deeplearning-platform-release \
  --boot-disk-size=100GB \
  --boot-disk-type=pd-ssd \
  --metadata-from-file=startup-script="$STARTUP" \
  --scopes=https://www.googleapis.com/auth/cloud-platform

rm -f "$STARTUP"

cat <<EOF

VM '$INSTANCE' is booting. Labeling begins automatically; the VM self-deletes when done.

Monitor (serial console is most reliable; IAP SSH can hang):
  gcloud compute instances get-serial-port-output $INSTANCE --zone $ZONE | tail -40

When the instance disappears from 'gcloud compute instances list', labeling is done. Then
train the classifier on these teacher labels (val crops are the held-out eval set):
  gsutil ls $BUCKET/labels/
  export TRAIN_LABELS=$BUCKET/labels/labels_gemini_train.csv
  export VAL_LABELS=$BUCKET/labels/labels_gemini_val.csv
  bash classification/launch_train.sh    # BACKBONE=clip VARIANT=clip_v1
  python -m autolabel.compare_labels --a autolabel/labels_gemini_val.csv \\
      --b ~/Downloads/product_labels_openai_val_normalized_categories.csv \\
      --b-is-truth --name-a Gemini --name-b GroundTruth
EOF
