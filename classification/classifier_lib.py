"""Model + dataset for the two-head crop classifier (shared by train + infer).

Two heads over the fixed taxonomy: an 18-way category head and a 48-way subcategory head.
At inference the subcategory head is MASKED to the children of the predicted category so the
two outputs are always consistent (the taxonomy is a clean tree).

Two backbones:
  - "clip"     : frozen open-clip image encoder + two linear heads. Fast, strong with few
                 labels, reuses the open-clip already pulled in. Recommended baseline.
  - "resnet50" : torchvision ResNet-50, ImageNet-pretrained, fine-tuned end-to-end. The
                 proposal's literal model — trained as a second experiment for the report.
"""
from __future__ import annotations

import csv
from pathlib import Path

import torch
import torch.nn as nn
from torch.utils.data import Dataset

from classification import taxonomy

CAT = "normalized_category"
SUB = "normalized_subcategory"


# --------------------------------------------------------------------------
# Dataset — joins a labels CSV (filename -> cat/subcat) to crop image files.
# --------------------------------------------------------------------------
class CropDataset(Dataset):
    def __init__(self, labels_csv: str, crops_dir: str, transform, tax: taxonomy.Taxonomy):
        self.transform = transform
        self.tax = tax
        crops_root = Path(crops_dir)
        # Index crop files by name so labels join regardless of split subdir.
        by_name = {p.name: p for p in crops_root.rglob("*") if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"}}
        self.items: list[tuple[Path, int, int]] = []
        missing = 0
        with open(labels_csv, newline="") as f:
            for r in csv.DictReader(f):
                cat, sub = r.get(CAT), r.get(SUB)
                if cat not in tax.cat_to_id or sub not in tax.sub_to_id:
                    continue
                p = by_name.get(r["filename"])
                if p is None:
                    missing += 1
                    continue
                self.items.append((p, tax.cat_to_id[cat], tax.sub_to_id[sub]))
        if missing:
            print(f"WARN: {missing} labeled rows had no matching crop file in {crops_dir}")

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        from PIL import Image

        path, cat_id, sub_id = self.items[i]
        img = self.transform(Image.open(path).convert("RGB"))
        return img, cat_id, sub_id

    def category_labels(self) -> list[int]:
        return [c for _, c, _ in self.items]


# --------------------------------------------------------------------------
# Model.
# --------------------------------------------------------------------------
class TwoHeadClassifier(nn.Module):
    def __init__(self, backbone: str, n_cat: int, n_sub: int,
                 clip_model: str = "ViT-B-32", clip_pretrained: str = "laion2b_s34b_b79k"):
        super().__init__()
        self.backbone_kind = backbone
        if backbone == "clip":
            import open_clip

            model, _, preprocess = open_clip.create_model_and_transforms(
                clip_model, pretrained=clip_pretrained
            )
            self.encoder = model.visual
            for p in self.encoder.parameters():  # freeze — train heads only
                p.requires_grad = False
            self.preprocess = preprocess
            feat_dim = self.encoder.output_dim if hasattr(self.encoder, "output_dim") else 512
        elif backbone == "resnet50":
            from torchvision import models, transforms

            net = models.resnet50(weights=models.ResNet50_Weights.IMAGENET1K_V2)
            feat_dim = net.fc.in_features
            net.fc = nn.Identity()
            self.encoder = net  # fine-tuned end-to-end
            self.preprocess = transforms.Compose([
                transforms.Resize(256),
                transforms.CenterCrop(224),
                transforms.ToTensor(),
                transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
            ])
        else:
            raise ValueError(f"unknown backbone {backbone}")

        self.cat_head = nn.Linear(feat_dim, n_cat)
        self.sub_head = nn.Linear(feat_dim, n_sub)

    def forward(self, x):
        if self.backbone_kind == "clip":
            with torch.no_grad():
                feat = self.encoder(x).float()
        else:
            feat = self.encoder(x)
        return self.cat_head(feat), self.sub_head(feat)


def make_model(backbone: str, tax: taxonomy.Taxonomy, **kw) -> TwoHeadClassifier:
    return TwoHeadClassifier(backbone, tax.n_categories, tax.n_subcategories, **kw)


def masked_subcategory_pred(cat_logits, sub_logits, tax: taxonomy.Taxonomy):
    """Given batch logits, return (cat_id, cat_conf, sub_id, sub_conf) where the subcategory
    is restricted to the children of the argmax category — guarantees consistency."""
    cat_prob = cat_logits.softmax(dim=-1)
    cat_conf, cat_id = cat_prob.max(dim=-1)
    sub_prob = sub_logits.softmax(dim=-1)
    sub_ids, sub_confs = [], []
    for b in range(cat_id.shape[0]):
        cols = tax.subcategory_ids_of(tax.category_names[int(cat_id[b])])
        col_tensor = torch.tensor(cols, device=sub_prob.device)
        masked = sub_prob[b, col_tensor]
        j = int(masked.argmax())
        sub_ids.append(cols[j])
        sub_confs.append(float(masked[j]))
    return cat_id, cat_conf, torch.tensor(sub_ids), torch.tensor(sub_confs)
