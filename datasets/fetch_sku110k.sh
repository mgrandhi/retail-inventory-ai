# Payload: download SKU-110K and cache it in $BUCKET/sku110k/.
# Sourced after _fetcher_lib.sh and with __BUCKET__ already substituted.

BUCKET="__BUCKET__"
DEST="$BUCKET/sku110k"
LOG=/tmp/fetch.log

_setup_logging "$LOG"
_setup_cleanup "$BUCKET" "$LOG" "sku110k/fetch.log"

echo "=== fetch_sku110k starting at $(date -u) ==="

# Tools.
apt-get update >/dev/null 2>&1 || true
apt-get install -y curl tar python3 >/dev/null 2>&1 || true

DL=/tmp/dl
mkdir -p "$DL"
cd "$DL"

URL="http://trax-geometry.s3.amazonaws.com/cvpr_challenge/SKU110K_fixed.tar.gz"
echo "=== downloading $URL ==="
curl --fail --location --retry 8 --retry-delay 5 --retry-all-errors \
     -A "curl/8.0" -o SKU110K_fixed.tar.gz "$URL"

ls -lh SKU110K_fixed.tar.gz

echo "=== uploading raw tarball -> $DEST/ ==="
gsutil -m cp SKU110K_fixed.tar.gz "$DEST/SKU110K_fixed.tar.gz"

echo "=== extracting locally ==="
mkdir -p extracted
tar -xzf SKU110K_fixed.tar.gz -C extracted

# Tarball expands to a single top-level dir SKU110K_fixed/.
ROOT=$(ls extracted | head -1)
echo "=== uploading extracted/$ROOT -> $DEST/extracted/ ==="
gsutil -m cp -r "extracted/$ROOT/." "$DEST/extracted/"

echo "=== writing manifest ==="
gsutil ls -l -r "$DEST/**" > /tmp/manifest.txt
gsutil cp /tmp/manifest.txt "$DEST/manifest.txt"

echo "=== fetch_sku110k done at $(date -u) ==="
