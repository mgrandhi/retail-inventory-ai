# Issue Log

Append-only. Newest at top. Each entry: **Date · Symptom · Root cause · Fix/Status**.
This log feeds the "Challenges & Lessons Learned" section of the final report.

---

## 2026-06-06 · Training hung at dataset download — `bufio.Scanner: token too long`
- **Symptom:** VM booted, L4 detected, dataset download started, then froze at ~22%. GPU at 0%/3MiB,
  no python process. Serial console showed `error while communicating with "startup-script" script:
  bufio.Scanner: token too long`. VM sat idle, billing.
- **Root cause:** The startup script used `exec > >(tee -a logfile)`, routing ALL YOLO output through
  GCP's metadata script-runner. YOLO's rich/tqdm progress bars use carriage returns (`\r`, no newline),
  so a whole download/epoch bar is one giant "line". GCP's script-runner reads stdout with a
  `bufio.Scanner` capped at 64KB/line; the bar overflowed it → runner tore down the child → training died.
- **Fix:** Redirect YOLO output **directly to a file** (`>> "$LOG" 2>&1`) instead of through the
  scanner; only short milestone `echo`s go to the console. Also set `TQDM_MININTERVAL=10` and
  `PYTHONUNBUFFERED=1` to reduce control-char spam. (The EXIT-trap cost-safety still self-deletes.)
- **Status:** ✅ fixed in `detection/train_sku110k.sh`; relaunching.

## 2026-06-06 · SSH port 22 times out (direct), IAP works
- **Symptom:** `gcloud compute ssh` (direct) to the VM times out on port 22.
- **Root cause:** Salesforce corp org-policy firewall blocks direct SSH ingress.
- **Fix:** Use `--tunnel-through-iap` for SSH, or monitor via
  `gcloud compute instances get-serial-port-output`. Not a blocker for training.
- **Status:** ✅ workaround (IAP). Note for all future VM debugging on this project.

## 2026-06-06 · `pytorch-latest-gpu` DLVM image family no longer exists
- **Symptom:** `gcloud compute instances create` failed: image family
  `projects/deeplearning-platform-release/global/images/family/pytorch-latest-gpu` not found.
- **Root cause:** Google retired the `*-latest-gpu` aliases; DLVM PyTorch families are now
  version-pinned (e.g. `pytorch-2-9-cu129-ubuntu-2204-nvidia-580`).
- **Fix:** Updated `detection/launch_vm.sh` to `--image-family=pytorch-2-9-cu129-ubuntu-2204-nvidia-580`
  (discovered via `gcloud compute images list --project=deeplearning-platform-release --filter="family~pytorch"`).
  VM created successfully on retry.
- **Status:** ✅ resolved.

## 2026-06-06 · Project proposal PDF would not extract as plain text
- **Symptom:** `Read` of the PDF failed (no poppler); naive stream extraction produced garbage.
- **Root cause:** The PDF uses an embedded CID font with a constant +0x1D code offset; text isn't
  stored as plain ASCII.
- **Fix:** Decompressed content streams with zlib and mapped each 2-byte glyph code → `chr(code +
  0x1D)` to recover readable text. Full proposal text recovered.
- **Status:** ✅ resolved.

## 2026-06-06 · T4 cannot hold batch=16 at imgsz=1280 (proposal's literal hyperparams)
- **Symptom:** Proposal specifies batch=16 @ 1280, which OOMs on a 16 GB T4.
- **Root cause:** YOLOv8m activations at 1280 exceed 16 GB VRAM at batch=16.
- **Fix:** Use Ultralytics auto-batch (`batch=-1`, targets ~60% VRAM). Moving to L4 (24 GB) also
  permits a larger batch. Documented as an expected, correct deviation.
- **Status:** ✅ resolved (by GPU choice + auto-batch).

## 2026-06-06 · Local gcloud not authenticated / config dir not writable in sandbox
- **Symptom:** `gcloud auth list` / `config get-value project` error with PermissionError on
  `~/.config/gcloud`; no project set.
- **Root cause:** Agent sandbox cannot write the gcloud config dir; no account logged in.
- **Fix:** User runs `gcloud auth login` + `gcloud config set project` themselves (suggested via
  `! gcloud auth login` in the Claude Code prompt).
- **Status:** ⚠️ user action required before training.
