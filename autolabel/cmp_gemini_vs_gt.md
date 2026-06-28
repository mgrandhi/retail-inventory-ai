# Label accuracy vs ground truth: Gemini vs GroundTruth

- Files in Gemini: 2000  ·  in GroundTruth: 15000  ·  joined on filename: 716

- **Category accuracy vs ground truth: 11.2%** (80/716)
- **Subcategory accuracy vs ground truth: 2.8%** (20/716)

## Per-category accuracy vs ground truth (reference = GroundTruth)

| Category | N | match % |
|---|---:|---:|
| Beverages | 217 | 24.0% |
| Personal Care & Beauty | 133 | 10.5% |
| Snacks & Confectionery | 100 | 2.0% |
| Hair Care | 63 | 0.0% |
| Oral Care | 57 | 0.0% |
| Household Cleaning & Laundry | 33 | 21.2% |
| Grocery & Pantry | 32 | 0.0% |
| Other / Unclear | 22 | 22.7% |
| Health & Wellness | 15 | 0.0% |
| Apparel & Accessories | 14 | 0.0% |
| Electronics | 7 | 0.0% |
| Automotive & Hardware | 6 | 0.0% |
| Home & Kitchen | 5 | 0.0% |
| Tobacco / Restricted | 4 | 0.0% |
| Baby Care | 4 | 0.0% |
| Paper & Hygiene | 4 | 0.0% |

## Top category confusions (GroundTruth → Gemini)

| GroundTruth category | Gemini predicted | count |
|---|---|---:|
| Beverages | Personal Care & Beauty | 85 |
| Beverages | Other / Unclear | 53 |
| Personal Care & Beauty | Beverages | 47 |
| Personal Care & Beauty | Household Cleaning & Laundry | 45 |
| Snacks & Confectionery | Other / Unclear | 36 |
| Oral Care | Other / Unclear | 32 |
| Snacks & Confectionery | Personal Care & Beauty | 29 |
| Snacks & Confectionery | Beverages | 28 |
| Hair Care | Beverages | 25 |
| Personal Care & Beauty | Other / Unclear | 24 |
| Hair Care | Other / Unclear | 19 |
| Oral Care | Personal Care & Beauty | 19 |
| Beverages | Household Cleaning & Laundry | 18 |
| Grocery & Pantry | Other / Unclear | 15 |
| Grocery & Pantry | Beverages | 15 |
| Household Cleaning & Laundry | Beverages | 12 |
| Household Cleaning & Laundry | Other / Unclear | 10 |
| Other / Unclear | Beverages | 9 |
| Health & Wellness | Other / Unclear | 9 |
| Hair Care | Household Cleaning & Laundry | 9 |
