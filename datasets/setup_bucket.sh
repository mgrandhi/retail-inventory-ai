#!/bin/bash
# One-time bucket creation for the dataset cache. Idempotent — safe to re-run.
#
#   export PROJECT_ID=<your-gcp-project>
#   bash datasets/setup_bucket.sh
#
# Creates: gs://${PROJECT_ID}-datasets  (Standard tier, us-central1, uniform IAM,
#                                         no public reads)
# Binds:   roles/storage.objectAdmin to the project's compute service account
#          (the same SA every training/fetcher VM uses).
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID (e.g. export PROJECT_ID=ehc-mgrandhi-bc801a)}"
LOCATION="${LOCATION:-us-central1}"
BUCKET="${DATASETS_BUCKET:-gs://${PROJECT_ID}-datasets}"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo "Project: $PROJECT_ID"
echo "Bucket:  $BUCKET"
echo "Region:  $LOCATION"
echo "SA:      $COMPUTE_SA"

# 1. Create the bucket (no-op if it already exists).
if gcloud storage buckets describe "$BUCKET" >/dev/null 2>&1; then
  echo "bucket already exists — skipping create"
else
  echo "creating bucket..."
  gcloud storage buckets create "$BUCKET" \
    --project="$PROJECT_ID" \
    --location="$LOCATION" \
    --default-storage-class=STANDARD \
    --uniform-bucket-level-access \
    --public-access-prevention
fi

# 2. Bind the compute SA as objectAdmin (idempotent — this command upserts).
echo "binding $COMPUTE_SA -> roles/storage.objectAdmin..."
gcloud storage buckets add-iam-policy-binding "$BUCKET" \
  --member="serviceAccount:$COMPUTE_SA" \
  --role=roles/storage.objectAdmin >/dev/null

# 3. Drop a top-level README object so the bucket is self-describing six months from now.
README="$(mktemp)"
cat > "$README" <<EOF
retail-inventory-ai dataset cache
==================================

Layout (one prefix per dataset):

  sku110k/
    SKU110K_fixed.tar.gz       <- raw 13.6 GB tarball
    extracted/                 <- {images,annotations}/ tree
    manifest.txt               <- gsutil hash output

  coco2017/
    zips/                      <- raw {train2017,val2017,test2017,annotations*}.zip
    extracted/                 <- {train2017,val2017,test2017,annotations}/
    manifest.txt

  rpc/
    raw/                       <- whatever the source ships (zip / tar)
    extracted/
    manifest.txt

Owner: project compute SA has roles/storage.objectAdmin.
Region: $LOCATION (Standard tier).
Created: $(date -u +%Y-%m-%dT%H:%M:%SZ) by datasets/setup_bucket.sh
EOF
gcloud storage cp "$README" "$BUCKET/README.txt"
rm -f "$README"

echo "done."
