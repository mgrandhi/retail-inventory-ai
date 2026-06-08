# Payload: download COCO 2017 (train/val/test images + annotations) and cache it in
# $BUCKET/coco2017/. Sourced after _fetcher_lib.sh with __BUCKET__ substituted.

BUCKET="__BUCKET__"
DEST="$BUCKET/coco2017"
LOG=/tmp/fetch.log

_setup_logging "$LOG"
_setup_cleanup "$BUCKET" "$LOG" "coco2017/fetch.log"

echo "=== fetch_coco2017 starting at $(date -u) ==="

apt-get update >/dev/null 2>&1 || true
apt-get install -y curl unzip python3 >/dev/null 2>&1 || true

DL=/tmp/dl
mkdir -p "$DL/zips" "$DL/extracted"
cd "$DL/zips"

# Five canonical zips from the official COCO CDN (stable AWS S3).
ZIPS=(
  "http://images.cocodataset.org/zips/train2017.zip"
  "http://images.cocodataset.org/zips/val2017.zip"
  "http://images.cocodataset.org/zips/test2017.zip"
  "http://images.cocodataset.org/annotations/annotations_trainval2017.zip"
  "http://images.cocodataset.org/annotations/image_info_test2017.zip"
)
for url in "${ZIPS[@]}"; do
  fn=$(basename "$url")
  echo "=== downloading $fn ==="
  curl --fail --location --retry 8 --retry-delay 5 --retry-all-errors \
       -A "curl/8.0" -o "$fn" "$url"
  ls -lh "$fn"
done

echo "=== uploading raw zips -> $DEST/zips/ ==="
gsutil -m cp ./*.zip "$DEST/zips/"

cd "$DL/extracted"
for fn in "$DL/zips"/*.zip; do
  echo "=== unzipping $(basename "$fn") ==="
  unzip -q "$fn"
done

echo "=== uploading extracted tree -> $DEST/extracted/ ==="
# COCO zips expand to: train2017/, val2017/, test2017/, annotations/
gsutil -m cp -r "$DL/extracted/." "$DEST/extracted/"

echo "=== writing manifest ==="
gsutil ls -l -r "$DEST/**" > /tmp/manifest.txt
gsutil cp /tmp/manifest.txt "$DEST/manifest.txt"

echo "=== fetch_coco2017 done at $(date -u) ==="
