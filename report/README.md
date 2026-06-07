# Final Report (LaTeX)

IEEE-conference-style report assembled **from** the running logs (`../DECISIONS.md`,
`../ISSUES.md`, `../RESULTS.md`) and figures produced by each module.

## Structure
- `main.tex` — document root; pulls in `sections/*.tex` and `references.bib`.
- `sections/` — one file per section (problem, literature, approach, datasets, experiments,
  results, conclusion). Stubs are pre-filled from the proposal; expand as work completes.
- `references.bib` — seeded with the 10 proposal references.
- `figures/` — drop `results.png`, PR/F1 curves, confusion matrix, and the notebook's
  `before_after_*.png` panels here, then uncomment the `\includegraphics` lines in
  `sections/06_results.tex`.

## Build
Locally (needs a TeX distribution, e.g. MacTeX):
```bash
cd report
latexmk -pdf main.tex      # produces main.pdf
latexmk -c                 # clean aux files
```
No LaTeX installed locally right now → easiest path is **Overleaf**: upload the `report/` folder
and compile there.

## Keeping it in sync
- Detection numbers: transcribe `../RESULTS.md` → Table in `sections/06_results.tex`
  (replace the `TBD`s) once `detection/metrics.json` is populated.
- Figures: copy from the GCS bucket (`gs://<project>-sku110k-yolo/results/` and `/figures/`).
