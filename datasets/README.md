# Datasets cache

A dedicated GCS bucket (`gs://${PROJECT_ID}-datasets`, by default
`gs://ehc-mgrandhi-bc801a-datasets`) that holds every dataset the project trains on,
pre-downloaded once. Future training VMs `gsutil cp` from it instead of streaming
13–30 GB through Cloud NAT each time.

## Layout

```
gs://<project>-datasets/
├── README.txt                  ← human-readable bucket-level layout note
├── _secrets/                   ← user-provided API tokens (e.g. kaggle.json)
├── sku110k/
│   ├── SKU110K_fixed.tar.gz    ← raw 13.6 GB tarball
│   ├── extracted/              ← {images,annotations}/ tree
│   ├── manifest.txt            ← gsutil-ls listing of all uploaded objects
│   └── fetch.log               ← fetcher VM's stdout
├── coco2017/
│   ├── zips/                   ← raw {train2017,val2017,test2017,annotations*}.zip
│   ├── extracted/              ← {train2017,val2017,test2017,annotations}/
│   ├── manifest.txt
│   └── fetch.log
└── rpc/
    ├── raw/                    ← whatever the source ships
    ├── extracted/
    ├── manifest.txt
    └── fetch.log
```

## Inventory

| Dataset    | Module          | Source (primary)                                                         | Approx size | Bucket prefix | Status     |
|------------|-----------------|--------------------------------------------------------------------------|-------------|---------------|------------|
| SKU-110K   | Detection (W3)  | `http://trax-geometry.s3.amazonaws.com/cvpr_challenge/SKU110K_fixed.tar.gz` | ~13.6 GB   | `sku110k/`    | **fetched 2026-06-08** (tarball + extracted tree, 23.5 GiB total) |
| COCO 2017  | Detection (W3+) | `http://images.cocodataset.org/zips/*.zip`                               | ~25 GB     | `coco2017/`   | **fetched 2026-06-08** (5 zips authoritative, 46.8 GiB total; `extracted/{train2017,test2017}/` only — `val2017` + `annotations` should be unzipped on demand from `zips/`) |
| RPC        | Classification (W4) | Kaggle mirror `diyer22/retail-product-checkout-dataset` (token required) | ~30 GB     | `rpc/`        | _pending fetch_ — needs `_secrets/kaggle.json` (see below) |

## How to fetch a dataset

```bash
export PROJECT_ID=ehc-mgrandhi-bc801a
# One-time bucket setup (idempotent):
bash datasets/setup_bucket.sh

# Per dataset (each round trip is ~3–15 min):
bash datasets/launch_dataset_fetcher.sh sku110k
bash datasets/launch_dataset_fetcher.sh coco2017
bash datasets/launch_dataset_fetcher.sh rpc
```

Each invocation:

1. Verifies Cloud NAT is provisioned in the launcher's region (aborts with the exact
   `gcloud compute routers create` fix command if not).
2. Creates an `e2-small` VM in `us-central1-a` with **no public IP** (egress through
   Cloud NAT, same security policy as our training VMs).
3. The VM downloads the dataset, extracts it, uploads everything to the bucket, then
   self-deletes via the same 3-layer trap (`gcloud delete` → REST DELETE →
   `at`-scheduled `shutdown -h +5`) used by `detection/train_sku110k.sh`.

Tail the live log via IAP:

```bash
gcloud compute ssh dataset-fetcher-sku110k --zone us-central1-a --tunnel-through-iap \
  --command "sudo tail -f /tmp/fetch.log"
```

## RPC: one-time Kaggle setup

The RPC dataset's only stable global mirror is on Kaggle, which requires an API token.

```bash
# 1. Visit https://www.kaggle.com/settings/account
# 2. "Create New API Token" downloads kaggle.json
# 3. Upload it to the bucket (one-time, per-user secret):
gsutil cp ~/Downloads/kaggle.json gs://ehc-mgrandhi-bc801a-datasets/_secrets/kaggle.json
# 4. Now run the fetcher:
bash datasets/launch_dataset_fetcher.sh rpc
```

If `_secrets/kaggle.json` is missing, the fetcher tries a github fallback, and if that
also fails it exits with an actionable message (the cleanup trap still cleans up the
VM, so no idle cost).

## Adding a new dataset

1. Drop a new payload at `datasets/fetch_<name>.sh` following the existing
   `fetch_sku110k.sh` shape: `_setup_logging`, `_setup_cleanup`, download to
   `/tmp/dl/`, `gsutil -m cp -r` to `$BUCKET/<name>/`, write `manifest.txt`.
2. Append a row to the **Inventory** table above with the source URL + approx size.
3. Run `bash datasets/launch_dataset_fetcher.sh <name>`.

No code-wide change needed — the launcher is generic.

## Wiring training scripts to use the cache

`detection/train_sku110k.sh` reads the cache before falling back to Ultralytics'
public-CDN download. Pattern (committed alongside this README in a follow-up commit):

```bash
if gsutil -q stat "$DATASETS_BUCKET/sku110k/SKU110K_fixed.tar.gz"; then
  mkdir -p /datasets && cd /datasets
  gsutil -q cp "$DATASETS_BUCKET/sku110k/SKU110K_fixed.tar.gz" .
  tar -xzf SKU110K_fixed.tar.gz && rm SKU110K_fixed.tar.gz
  export YOLO_DATASETS_DIR=/datasets
fi
yolo detect train data=SKU-110K.yaml ...
```

The fallback to public-CDN download is preserved — a fresh project clone with no cache
still works, just slower.

## Cost

| Item                                     | One-time   | Recurring |
|------------------------------------------|------------|-----------|
| Three fetcher VMs (e2-small, 5–15 min ea)| ~$0.05     | —         |
| Bucket storage (~70 GB Standard)         | —          | ~$1.40/mo |
| NAT data processing for the three fetches| ~$3.20     | —         |
| Per-future-training-run savings          | —          | −$0.45 to −$0.60 |

Cache pays for itself after ~6 training runs.
