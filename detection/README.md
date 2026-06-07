# Module 1 — Detection (YOLOv8m on SKU-110K)

Fine-tunes YOLOv8m (COCO-pretrained) on the SKU-110K dense-retail dataset on a **GCP L4 GPU VM**,
captures **mAP@0.5** and **mAP@0.5:0.95**, syncs everything to GCS, and self-deletes the VM.

## Files
- `train_sku110k.sh` — VM startup script (trains → validates → metrics.json → GCS → self-delete).
- `launch_vm.sh` — local launcher that creates the L4 VM with the startup script attached.
- `teardown.sh` — safety-net manual VM delete (auto-delete is the normal path).

## Prerequisites (run once, locally)
```bash
gcloud auth login                       # the agent can't do this — sandbox can't write gcloud config
export PROJECT_ID=<your-gcp-project-id>
export REGION=us-central1
export ZONE=us-central1-a
export BUCKET=gs://${PROJECT_ID}-sku110k-yolo

gcloud config set project "$PROJECT_ID"
gcloud services enable compute.googleapis.com
gsutil mb -l "$REGION" "$BUCKET"
```
> **Quota:** need `NVIDIA_L4_GPUS` ≥ 1 in `us-central1`
> (`gcloud compute regions describe us-central1`). If 0, request an increase, or use the 2×T4
> fallback (see below).

## Run
```bash
bash detection/launch_vm.sh
```
Training begins automatically (~10h, `time=9.5` hard cap), then the VM self-deletes.

## Monitor
```bash
gcloud compute ssh sku110k-train --zone "$ZONE" --command "tail -f /opt/runs/train.log"
gcloud compute instances list      # when sku110k-train is gone, training finished
```

## Results
```bash
gsutil cat $BUCKET/results/metrics.json          # mAP_50 and mAP_50_95
gsutil -m cp -r $BUCKET/results ./detection/      # pull artifacts (best.pt, results.png, ...)
```
Then transcribe the numbers into `../RESULTS.md` and copy `results.png` etc. into `../report/figures/`.

## Config (what & why)
| Setting | Value | Why |
|---|---|---|
| model | `yolov8m.pt` | COCO-pretrained medium variant (proposal spec) |
| data | `SKU-110K.yaml` | Ultralytics built-in; auto-downloads ~13.6 GB dataset |
| imgsz | 1280 | dense small objects need high resolution (proposal spec) |
| time | 9.5 | hard wall-clock cap → bounded ~10h run + cost |
| epochs | 50 | upper bound; time cap usually stops first |
| batch | -1 | auto-batch (~60% VRAM); fits L4 24 GB at 1280 |
| cos_lr | True | cosine LR schedule (proposal spec) |
| GPU | 1× L4 (`g2-standard-8`) | ~2–3× T4, single-GPU, 24 GB VRAM |

## Fallback — no L4 quota (use 2×T4)
Edit `launch_vm.sh`:
```
--machine-type=n1-highmem-8 --accelerator=type=nvidia-tesla-t4,count=2
```
and add `device=0,1` to the `yolo detect train` command in `train_sku110k.sh` (enables DDP).
~$1.18/hr, ~$11–12 for the run.
