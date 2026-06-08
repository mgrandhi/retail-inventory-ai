#!/bin/bash
# Shared helpers for dataset fetcher VMs. Source this from any fetch_<name>.sh.
# These functions are designed to run as part of a VM startup script (root),
# but the trap helpers also work on the laptop side of the launcher.
#
# Provides:
#   _setup_logging  <log_path>                         set up tee'd logging to a file
#   _setup_cleanup  <bucket> <log_path> <bucket_logs>  install the 3-layer EXIT trap
#                                                       (gcloud delete -> REST -> shutdown)
#   _gsutil_upload  <bucket_prefix> <local_dir>        gsutil -m cp -r + manifest.txt

set -uo pipefail

# Tee all stdout+stderr to the given file. Returns immediately.
_setup_logging() {
  local log="$1"
  mkdir -p "$(dirname "$log")"
  : > "$log"
  exec > >(tee -a "$log") 2>&1
}

# Install the same 3-layer self-delete trap we use in detection/train_sku110k.sh.
# Args:
#   $1 — GCS bucket URI (gs://...)
#   $2 — path to local log file to upload before destruction
#   $3 — bucket subpath where the log should land (e.g. "sku110k/fetch.log")
_setup_cleanup() {
  local bucket="$1" log="$2" log_dest="$3"
  cleanup() {
    local rc=$?
    echo "=== cleanup (exit code $rc): syncing log to GCS ==="
    gsutil cp "$log" "$bucket/$log_dest" || echo "WARN: log upload failed"

    local NAME ZONE PROJECT TOKEN
    NAME=$(curl -sf -H "Metadata-Flavor: Google" \
      http://metadata.google.internal/computeMetadata/v1/instance/name)
    ZONE=$(curl -sf -H "Metadata-Flavor: Google" \
      http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
    PROJECT=$(curl -sf -H "Metadata-Flavor: Google" \
      http://metadata.google.internal/computeMetadata/v1/project/project-id)
    TOKEN=$(curl -sf -H "Metadata-Flavor: Google" \
      http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

    # Layer 3 — last-resort kill switch. Fires regardless of API state.
    apt-get install -y at >/dev/null 2>&1 || true
    echo "shutdown -h now" | at now + 5 minutes 2>/dev/null || \
      (sleep 300 && shutdown -h now) &

    # Layer 1 — gcloud SDK delete.
    echo "=== deleting self via gcloud: $NAME in $ZONE ==="
    gcloud compute instances delete "$NAME" --zone "$ZONE" --quiet || \
      echo "WARN: gcloud delete failed"

    # Layer 2 — REST DELETE if VM is still alive 30s later.
    sleep 30
    echo "=== fallback: REST API DELETE ==="
    curl -sf -X DELETE -H "Authorization: Bearer $TOKEN" \
      "https://compute.googleapis.com/compute/v1/projects/$PROJECT/zones/$ZONE/instances/$NAME" \
      || echo "WARN: REST delete failed"
  }
  trap cleanup EXIT
}

# gsutil -m cp the contents of $local_dir to $bucket_prefix, then write manifest.txt.
_gsutil_upload() {
  local bucket_prefix="$1" local_dir="$2"
  echo "=== uploading $local_dir -> $bucket_prefix ==="
  gsutil -m cp -r "$local_dir/." "$bucket_prefix/"
  echo "=== writing manifest ==="
  gsutil ls -l -r "$bucket_prefix/**" > /tmp/manifest.txt || true
  gsutil cp /tmp/manifest.txt "$bucket_prefix/manifest.txt"
  echo "=== upload done ==="
}
