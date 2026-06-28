# Label agreement: CLIP vs Gemini

- Files in CLIP: 92597  ·  in Gemini: 2000  ·  joined on filename: 2000

- **Category agreement: 24.2%** (485/2000)
- **Subcategory agreement: 18.4%** (368/2000)

## Per-category agreement (reference = Gemini)

| Category | N | match % |
|---|---:|---:|
| Other / Unclear | 566 | 50.2% |
| Personal Care & Beauty | 554 | 2.5% |
| Beverages | 352 | 27.0% |
| Paper & Hygiene | 215 | 14.9% |
| Health & Wellness | 150 | 2.7% |
| Household Cleaning & Laundry | 99 | 48.5% |
| Snacks & Confectionery | 23 | 4.3% |
| Hair Care | 18 | 27.8% |
| Oral Care | 14 | 14.3% |
| Baby Care | 2 | 0.0% |
| Grocery & Pantry | 2 | 0.0% |
| Automotive & Hardware | 2 | 0.0% |
| Tobacco / Restricted | 1 | 0.0% |
| Electronics | 1 | 0.0% |
| Pet Care | 1 | 0.0% |

## Top category confusions (Gemini → CLIP)

| Gemini category | CLIP predicted | count |
|---|---|---:|
| Personal Care & Beauty | Oral Care | 198 |
| Beverages | Tobacco / Restricted | 116 |
| Other / Unclear | Tobacco / Restricted | 102 |
| Personal Care & Beauty | Tobacco / Restricted | 82 |
| Paper & Hygiene | Oral Care | 77 |
| Personal Care & Beauty | Hair Care | 66 |
| Health & Wellness | Tobacco / Restricted | 62 |
| Other / Unclear | Oral Care | 52 |
| Personal Care & Beauty | Beverages | 49 |
| Beverages | Other / Unclear | 43 |
| Personal Care & Beauty | Household Cleaning & Laundry | 40 |
| Personal Care & Beauty | Other / Unclear | 38 |
| Health & Wellness | Household Cleaning & Laundry | 31 |
| Other / Unclear | Household Cleaning & Laundry | 30 |
| Beverages | Hair Care | 28 |
| Beverages | Oral Care | 27 |
| Paper & Hygiene | Tobacco / Restricted | 26 |
| Personal Care & Beauty | Paper & Hygiene | 22 |
| Other / Unclear | Beverages | 19 |
| Health & Wellness | Oral Care | 18 |

## Decision

Low agreement → trust the VLM labels and budget the VLM for the full set. (category agreement = 24.2%)
