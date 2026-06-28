# Label accuracy vs ground truth: CLIP vs GroundTruth

- Files in CLIP: 92597  ·  in GroundTruth: 15000  ·  joined on filename: 13360

- **Category accuracy vs ground truth: 7.0%** (935/13360)
- **Subcategory accuracy vs ground truth: 2.5%** (329/13360)

## Per-category accuracy vs ground truth (reference = GroundTruth)

| Category | N | match % |
|---|---:|---:|
| Beverages | 3711 | 9.6% |
| Personal Care & Beauty | 2537 | 2.2% |
| Hair Care | 1232 | 5.7% |
| Other / Unclear | 948 | 19.4% |
| Snacks & Confectionery | 911 | 2.4% |
| Household Cleaning & Laundry | 873 | 12.6% |
| Health & Wellness | 708 | 0.4% |
| Oral Care | 530 | 17.4% |
| Paper & Hygiene | 480 | 1.2% |
| Home & Kitchen | 457 | 1.5% |
| Grocery & Pantry | 272 | 1.5% |
| Baby Care | 267 | 3.0% |
| Apparel & Accessories | 166 | 1.8% |
| Automotive & Hardware | 80 | 1.2% |
| Tobacco / Restricted | 65 | 20.0% |
| Electronics | 63 | 0.0% |
| Stationery & Office | 45 | 0.0% |
| Pet Care | 15 | 0.0% |

## Top category confusions (GroundTruth → CLIP)

| GroundTruth category | CLIP predicted | count |
|---|---|---:|
| Beverages | Other / Unclear | 859 |
| Beverages | Oral Care | 704 |
| Beverages | Tobacco / Restricted | 551 |
| Personal Care & Beauty | Other / Unclear | 486 |
| Beverages | Household Cleaning & Laundry | 408 |
| Personal Care & Beauty | Oral Care | 405 |
| Personal Care & Beauty | Beverages | 404 |
| Personal Care & Beauty | Tobacco / Restricted | 378 |
| Hair Care | Other / Unclear | 274 |
| Personal Care & Beauty | Household Cleaning & Laundry | 247 |
| Snacks & Confectionery | Other / Unclear | 243 |
| Beverages | Hair Care | 240 |
| Hair Care | Tobacco / Restricted | 199 |
| Hair Care | Beverages | 198 |
| Hair Care | Oral Care | 186 |
| Other / Unclear | Oral Care | 183 |
| Household Cleaning & Laundry | Oral Care | 177 |
| Personal Care & Beauty | Hair Care | 172 |
| Health & Wellness | Oral Care | 170 |
| Snacks & Confectionery | Tobacco / Restricted | 152 |
