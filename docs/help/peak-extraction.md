# Internal standard exploration

This is the only standalone analysis tool. Its calculations are taken from lipidflowshiny Small Tools → Internal standard exploration.

1. Choose POS, NEG or both, and one QC mzML/mzXML file per selected polarity.
2. Load an internal-standard CSV with `ID`, `Name`, `Formula`, `Accurate_Mass`. Mass must be numeric and positive; blank IDs are automatically generated. Accurate_Mass is the neutral mass.
3. Select candidate adducts: POS +H / +Na / +NH4; NEG -H / +Cl / +HCOO.
4. Choose the ppm tolerance. Leave RT tolerance blank to search the whole run.
5. Run extraction. The real `lipidflow::extract_targeted_peaks()` performs peak detection and integration.
6. In Results, choose POS or NEG. Use **Review peak shapes** for a compact, independently scrolling standard list on the left and a fixed review area on the right. **Final result table** shows all result columns and supports sorting. Click a row (or press Enter on a focused row) to review that standard. **Inputs & parameters** opens the input panel when you need to rerun extraction.
7. The **Peak shapes** tab overlays all available adduct/sample EIC traces. **Adduct details** shows the candidate metrics in a separate tab. The adduct selector and confirmation buttons stay above both tabs. Use the Adducts and Samples checkboxes to hide or show traces. Hover for RT and intensity, drag horizontally to zoom, and use Reset zoom to restore the full run. Normalize each trace to compare shapes independently of signal magnitude.
8. Choose an adduct and click **Confirm adduct**. This immediately saves a new result revision with Selection_Source = manual and updates the final Y_IS_opt table. Other internal standards and the other polarity retain their selections. **Restore automatic selection** clears the manual choice for this standard only. Run history preserves previous revisions.
9. Export results. Use `tables/POS_Y_IS_opt.csv` and `tables/NEG_Y_IS_opt.csv` for workflow quantification.

Each polarity uses one QC file for peak-shape review, automatic adduct selection and the final quantitative area. Automatic scoring uses 0.6 × normalized peak area + 0.4 × peak shape, matching the actual Shiny implementation. If traces are unavailable, upstream scoring falls back to area, as recorded in the run log.

Existing projects remain readable, including any previously saved comparison traces. New extractions use only the selected QC file. EIC data are saved in POS_eic.json / NEG_eic.json; upstream detailed peak plots remain in the extraction directories.

## Download selected results

Open **Download results** below **Internal standard exploration** in the left sidebar. On this separate page, choose a polarity and click **Download selected results** to save that polarity from the latest completed result into a new folder under the project's `exports/` directory. Your file browser opens the folder when saving finishes. The export contains the full final Y_IS_opt CSV, one SVG peak-shape figure and raw trace CSV per internal standard for its saved selected adduct, an `index.html` gallery, and a manifest with the source run ID. All available samples are included regardless of the screen's visibility/filter settings. Confirm a pending adduct choice before downloading. Missing EIC data are explicitly reported. Earlier downloads are preserved.
