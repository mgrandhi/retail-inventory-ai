# Payload: download the RPC (Retail Product Checkout) dataset and cache it in
# $BUCKET/rpc/. Sourced after _fetcher_lib.sh with __BUCKET__ substituted.
#
# RPC has no single stable mirror. We probe sources in order:
#   1) The diyer22/retail-product-checkout-dataset Kaggle mirror (global, stable).
#      Requires a Kaggle API token in $BUCKET/_secrets/kaggle.json (created by user
#      via Kaggle Account -> Create New API Token).
#   2) The raw GitHub release of RPC's published assets (smaller subset; checked
#      only if Kaggle path fails).
#
# If both fail, we exit with rc=2 and the trap still cleans up the VM.

BUCKET="__BUCKET__"
DEST="$BUCKET/rpc"
LOG=/tmp/fetch.log

_setup_logging "$LOG"
_setup_cleanup "$BUCKET" "$LOG" "rpc/fetch.log"

echo "=== fetch_rpc starting at $(date -u) ==="

apt-get update >/dev/null 2>&1 || true
apt-get install -y curl unzip python3 python3-pip >/dev/null 2>&1 || true

# Work on the boot disk, NOT tmpfs. The boot disk is 80 GB; RAM on the fetcher
# is small, so anything memory-backed will OOM on a 30 GB dataset.
DL=/var/tmp/dl
mkdir -p "$DL/raw" "$DL/extracted"
cd "$DL/raw"

# --- Source 1: Kaggle REST API via curl (NOT the kaggle CLI) ----------------
# History: the `kaggle` CLI buffers the whole response in memory on large
# datasets; on an 83 GB download that triggers the kernel OOM-killer, which
# hard-kills the VM before any userspace trap/log can run (3 crashes, 0 logs).
# curl streams straight to disk at constant memory — the memory-safe path.
SLUG="diyer22/retail-product-checkout-dataset"
echo "=== probing Kaggle source ==="
if gsutil -q stat "$BUCKET/_secrets/kaggle.json"; then
  echo "Kaggle token found — downloading via Kaggle REST API with curl (streamed to disk)"
  gsutil cp "$BUCKET/_secrets/kaggle.json" /tmp/kaggle.json
  KUSER=$(python3 -c 'import json;print(json.load(open("/tmp/kaggle.json"))["username"])')
  KKEY=$(python3 -c 'import json;print(json.load(open("/tmp/kaggle.json"))["key"])')

  ZIP="$DL/raw/rpc.zip"
  API="https://www.kaggle.com/api/v1/datasets/download/${SLUG}"
  echo "=== streaming $API -> $ZIP ==="
  # -L follows the redirect to GCS/S3; --output streams to disk; -C - resumes
  # if a retry kicks in. Constant memory regardless of archive size.
  if curl --fail --location --retry 8 --retry-delay 10 --retry-all-errors \
        -C - -u "${KUSER}:${KKEY}" -o "$ZIP" "$API"; then
    echo "download OK"
    ls -lh "$ZIP"
    df -h "$DL" | tail -1
    echo "=== uploading raw archive -> $DEST/raw/ ==="
    gsutil -m cp "$ZIP" "$DEST/raw/rpc.zip"
    echo "RPC raw archive cached. (Extraction deferred to training time.)"
  else
    echo "WARN: curl download failed; trying secondary source"
    rm -rf "${DL:?}/raw"/* "${DL:?}/extracted"/*
  fi
else
  echo "no Kaggle token at $BUCKET/_secrets/kaggle.json — skipping Kaggle source"
fi

# --- Source 2: github release fallback (small subset, may not be full dataset) -
if [[ -z "$(ls -A "$DL/extracted" 2>/dev/null)" ]]; then
  echo "=== attempting github fallback ==="
  # The original RPC release page links to raw zips on the public github release
  # for github.com/RetailAI/RPC-Dataset (canonical author release).
  # If they ever 404, the script exits non-zero and the trap cleans up.
  GH_URL="https://github.com/RetailAI/RPC-Dataset/releases/download/v1.0/rpc.tar.gz"
  if curl --fail --silent --head "$GH_URL" >/dev/null; then
    echo "downloading $GH_URL"
    curl --fail --location --retry 5 --retry-delay 5 -o rpc.tar.gz "$GH_URL"
    tar -xzf rpc.tar.gz -C "$DL/extracted"
  else
    cat <<EOF
ERROR: no working RPC source.
  - Kaggle: token missing at $BUCKET/_secrets/kaggle.json or download failed.
  - GitHub: $GH_URL not reachable.

To enable Kaggle:
  1. Visit https://www.kaggle.com/settings/account -> Create New API Token
  2. gsutil cp ~/Downloads/kaggle.json $BUCKET/_secrets/kaggle.json
  3. Re-run: bash datasets/launch_dataset_fetcher.sh rpc
EOF
    exit 2
  fi
fi

# Upload the extracted tree only if a fallback source produced one (the Kaggle
# path is download-only). Empty extracted/ is fine — raw/ is authoritative.
if [[ -n "$(ls -A "$DL/extracted" 2>/dev/null)" ]]; then
  echo "=== uploading extracted -> $DEST/extracted/ ==="
  gsutil -m cp -r "$DL/extracted/." "$DEST/extracted/"
fi

echo "=== writing manifest ==="
gsutil ls -l -r "$DEST/**" > /tmp/manifest.txt
gsutil cp /tmp/manifest.txt "$DEST/manifest.txt"

echo "=== fetch_rpc done at $(date -u) ==="
