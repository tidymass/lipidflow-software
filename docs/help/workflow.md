# Untargeted lipidomics workflow

## Data import

Choose POS, NEG or both. Start with one of three input types:

- **Raw data folder:** choose one parent folder for each polarity. Place mzML/mzXML files directly inside its sample-group subfolders (for example `POS/QC/sample1.mzXML` and `POS/D25/sample2.mzXML`). Subfolder names define groups; filenames do not. Raw filenames must be unique across groups within a polarity. Files at the parent level or deeper nested raw files are rejected. Raw files stay at their original locations until peak picking stages a run-local copy preserving these groups. Avoid naming a group `Result` or `Results`, which are reserved for processing output.
- **Existing objects:** mass_dataset RDA/RData or RDS objects from peak picking. Continue directly to annotation.
- **Existing tables:** peak table and annotation table CSVs. Continue directly to absolute quantification. Peak tables contain variable_id, mz, rt and numeric sample intensity columns; annotation tables identify variable_id and Compound.name (or name).

Internal-standard inputs are provided only at Absolute quantification, not during import. Retention times are in seconds.

## Peak picking

Uses `massprocesser::process_data()` and xcms CentWave. Defaults match Shiny: 15 ppm, 10–60 s peak widths, S/N 5, noise 500, minimum fraction 0.5. Workers = 0 selects a memory-aware count capped at four. POS and NEG run sequentially and remain separate objects. A new run directory avoids reuse of old peak-picking caches.

Peak tables and mass_dataset RDA files are saved. QC figures produced by massprocesser are in the raw/POS or raw/NEG Result folder of the run.

## Lipid annotation

Choose MS2 files separately for each polarity. The bundled MS-DIAL-derived metid databases from lipidflowshiny are used unless a custom database is selected. Defaults: MS1 15 ppm, MS2 20 ppm, MS2 match tolerance 0.02, three candidates, MS1–MS2 linkage 10 ppm / 20 s, RT database matching disabled. Uses massdataset::mutate_ms2 and metid::annotate_metabolites_mass_dataset.

The pinned MS-DIAL library stores precursor m/z. The desktop adapter matches those values directly with metid and restores the library adduct labels, avoiding a second adduct mass shift. Custom databases default to standard metid neutral-mass semantics; choose Precursor m/z only for libraries using that convention.

The flat table uses Shiny's best-candidate-per-feature helper. The saved RDA retains the annotated object. An annotation is a candidate assignment, not structural proof.

## Absolute quantification

Upload an XLSX concentration table with `name`, `exact.mass`, `formula`, `ug_ml`, `um`. Choose the matching **POS Y_IS_opt** and **NEG Y_IS_opt** files; do not substitute the combined reference table for a polarity-specific measurement.

The engine calls Shiny's table adapter and `lipidflow::get_absolute_quantification`. It uses the ratio of lipid peak area to QC-derived internal-standard area, multiplied by the supplied concentration. Class-to-standard mapping is inferred from names, or overridden with JSON such as `{"PC":["PC standard"]}`. Features with unmatched classes are omitted by the upstream method. Review quantified versus input feature counts. The upstream package currently requires at least two sample columns.

## Results and export

Run **Prepare export** to produce the full quantification bundle, including unit-specific workbooks, lipid-class tables, composition PDFs and intensity plots. The download icon exports the selected run folder. The folder icon opens it in your file browser. Tables show up to 1,000 rows; the CSV contains all rows.

Earlier successful runs remain available in Run history. Re-running an upstream stage invalidates downstream workflow results as active inputs without deleting historical artifacts.
