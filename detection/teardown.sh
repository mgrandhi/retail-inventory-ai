#!/bin/bash
# Safety-net manual teardown. The VM normally self-deletes after training; run this only if
# auto-delete didn't fire (e.g. training crashed) and you want to stop paying for the GPU.
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
ZONE="${ZONE:-us-central1-a}"
INSTANCE="${INSTANCE:-sku110k-train}"

echo "Instances currently running:"
gcloud compute instances list --project="$PROJECT_ID" || true

echo
read -r -p "Delete instance '$INSTANCE' in '$ZONE'? [y/N] " ans
if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
  gcloud compute instances delete "$INSTANCE" --zone "$ZONE" --project="$PROJECT_ID" --quiet
  echo "Deleted. (GCS bucket and results are retained.)"
else
  echo "Aborted — nothing deleted."
fi
