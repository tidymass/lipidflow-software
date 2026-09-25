# LipidFlow Desktop validation

Latest Windows results: [0.1.12 acceptance record](validation/windows-0.1.12.md).

## Historical macOS 0.1.0 validation

Validated on macOS / Apple Silicon, 2026-09-25. These checks validate software behavior, not biological performance or identification accuracy in an independent cohort.

| Check | Evidence |
|---|---|
| TypeScript + production build | `npm run build` passes |
| Workflow ancestry and stale-input protection | Four Node tests pass |
| Bundled R dependencies | All required package namespaces load |
| CSV import → absolute quantification → export | Known synthetic area ratios yield expected concentrations (e.g. 2000 / 1000 × 20 = 40 uM); workbooks and plots created |
| Raw peak picking | Four upstream POS mzXML example files; 13,848 aligned features across four samples, using CentWave defaults and one worker |
| Peak Extraction | Real upstream QC raw file, two candidate adducts; integration, EIC traces and Y_IS_opt output complete |
| Manual adduct selection | New selection run created from saved extraction data |
| Lipid annotation | Two synthetic queries from reference spectra match two reference entries with the precursor-mass adapter; no independent performance claim |
| Packaged application | LipidFlow.app 0.1.0 / org.lipidflow.desktop; bundled R quantification and saved-project reopen pass in the packaged executable |
| Electron UI | One workflow and one tool; project creation/reopen, real R quantification, result table and light/dark screenshots verified |

Evidence is under [validation/](validation/). The R environment emits an inherited mzR/Rcpp build-version warning; raw-data reading and extraction passed despite that warning.

## Compatibility changes

- The existing TidyMass MSnbase metadata-constructor adapter is retained for massprocesser.
- MGF parsing uses explicit lists to handle multiple equal-length spectra; measured values and spectrum matching remain unchanged.
- The supplied MS-DIAL databases store precursor ion m/z, whereas ordinary metid databases use neutral mass. For precursor libraries, a local metid adapter supplies a zero adduct shift and restores each reference's original Adduct label. Scoring and ranking stay in metid. Custom databases have an explicit mass-convention selector.
- Empty annotation results are reported as empty candidate tables, and are rejected as quantification input.

## Practical limits

The 0.1.0 validation described above was an unsigned local Apple Silicon preview; Intel, Windows and Linux were not validated at that milestone. See [Windows build and validation](development/windows.md) for the later Windows port and [test-data provenance](validation/test-data.md) for the datasets used. Quantification intentionally follows the Shiny QC-area method, including upstream class matching; it is not a per-sample isotope-dilution workflow. POS raw examples and reference-spectrum fixtures were used for validation; complete POS+NEG biological study validation is still needed with the user's study data. The current upstream quantification implementation requires at least two sample columns.


## 0.1.5 internal-standard review

- Read the pinned Shiny `mod_small_tools.R` and `utils_small_tools.R` EIC/scoring/selection implementations. The scientific scoring weights remain 0.6 area + 0.4 shape.
- `npm test` passes workflow guards. `npm run test:exploration` uses an explicitly synthetic two-standard, two-polarity, two-sample fixture and the real Electron/R save path. It verifies numeric sorting, row selection, adduct/sample visibility, hover, zoom, consecutive manual overrides, polarity retention, reopening, and restoring automatic selection without losing other overrides.
- Real extraction ran against vendor `M19_1.mzXML` (QC) and `M19_2.mzXML` (comparison), with +H/+Na. Verified four full EIC traces with sample identities, four sample-candidate rows, and one final IS row. Reproducible with `npm run test:exploration:raw`. Real NEG multi-sample extraction was not repeated; NEG review/persistence is covered by the synthetic fixture.
- Reviewed rendered screenshots and corrected the polarity selector width and sample/adduct column placement. TypeScript and Vite build pass.
- Additional samples are comparison measurements; the chosen QC supplies the final quantitative area and automatic ranking. Existing single-QC run files remain compatible. Selection revisions retain the original source result and write updated final CSVs.

## 0.1.10 review layout

- Replaced the vertically stacked review with an independently scrolling standard list and an adjacent detail area. Final table, peak shapes and candidate details remain accessible through explicit tabs; confirmation controls remain above the detail tabs.
- Checked real two-sample EIC rendering at 1080×700, 1440×900 and 2200×950. Document height equals viewport height in each case.
- The Electron/R regression passed numeric sorting, selection by standard ID, visibility filters, hover, zoom, consecutive manual confirmations, cross-polarity persistence, reopening, restoring automatic selection, detail tabs and opening/closing input controls. Bounds assertions include the success banner at the minimum window size.
- SVG axes use the measured chart dimensions and pointer coordinates use the SVG screen transform, keeping zoom accurate after resizing.
