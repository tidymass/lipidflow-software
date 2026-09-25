# Helper functions used by mod_quantification.R.
#
# These are deliberately NOT exported - they're internal plumbing. Kept in
# their own file so the module file itself stays readable.
#
# ARCHITECTURE CHANGE (see project discussion): Step 3 used to call
# lipidflow::extract_targeted_peaks() TWICE against the original raw mzXML
# files (once for the Internal Standard targets, once for the lipid targets)
# on every run - the same shape as pipeline_EIC_auto.R's own section 5/6.
# That made Step 3 the slowest stage in the app AND meant it could never run
# from "Load Existing Result" alone (it always needed pipeline_state$pp_work_dir,
# the raw POS/NEG folder, which only exists when Step 1 ran Option A).
#
# Step 3 now builds its 2 input tables ENTIRELY from tables already produced
# by earlier steps - no raw file access, no BiocParallel worker pool - and
# hands them to the REAL, unmodified package function:
#
#   lipidflow::get_absolute_quantification()  (-> lipidflow:::cal_abs())
#
# per direct agreement with the app's owner, who is developing this app on
# top of lipidflow 0.0.1 specifically: using the package's own tested
# quantification function is preferred over a hand-rolled formula, even
# though the two are mathematically equivalent for the core ratio. Confirmed
# by reading cal_abs()'s real source (not guessed) that it needs NO raw
# files at all - `path` is only ever used to save() intermediate .rda
# bookkeeping files, never read from:
#
#   Area_lipid = looked up directly from Step 1's peak_table (no re-scan)
#   Area_IS    = looked up directly from Y_IS_opt - ONE value per Internal
#                Standard (measured once from a QC injection), broadcast
#                across every sample column, since Y_IS_opt currently only
#                ever holds one QC-derived measurement per IS
#   C_IS       = the Internal Standard's known concentration (Data Import's
#                Internal Standard table: ug_ml / um)
#   Class match     - which Internal Standard(s) normalize which lipid Class
#                     is now AUTO-INFERRED (.lfs_infer_class_to_is(), ported
#                     from the teammate's V5 script, adopted per direct
#                     agreement) by matching each Class token against the
#                     names actually present in Y_IS_opt/is_table - not a
#                     static hardcoded table anymore, so a custom Internal
#                     Standard named outside the old fixed 16-class list is
#                     no longer silently unmatched. An explicit match_item
#                     can still be passed in to override the auto-inferred
#                     one (e.g. .lfs_default_match_item_pos()/_neg(), kept
#                     around for that).
#   IS tie-break    - when a Class has more than 1 candidate IS, which one
#                     wins is handled INSIDE cal_abs() (not reimplemented
#                     here): it picks whichever candidate's own rt is
#                     closest to the lipid feature's rt, not "first in the
#                     list".
#
# cal_abs()'s own real behavior (kept as-is, per direct agreement - do not
# silently override it again):
#   - A lipid whose Class has no match_item entry at all is DROPPED from
#     the output entirely (not kept with NA).
#   - A lipid whose Class DOES match, but the specific per-sample ratio
#     comes out Inf/NA (e.g. Area_IS 0 for that IS), gets 0 for that one
#     cell, not NA.
# mod_quantification.R surfaces "N of M features quantified" using this
# function's n_input/n_quantified return values, so a dropped-row count
# is visible instead of features silently vanishing from the table.
#
# Known real limitation in lipidflow 0.0.1's own cal_abs() (confirmed by
# hitting it directly, not guessed): it does `lipid_table[remain_idx, ]`/
# `is_table[remain_idx, ]` without drop = FALSE, which base R silently
# collapses to a plain vector (not a data.frame) whenever there is only 1
# sample column - a run with just 1 sample crashes a few lines later with
# "incorrect number of dimensions". Not something this wrapper can fix from
# the outside; not a practical concern for a real study (always >=2 samples).

# ---------------------------------------------------------------------------
# Default IS <-> lipid class matches, copied verbatim from the defaults baked
# into lipidflow::get_lipid_absolute_quantification()'s own function
# signature (see jaspershen/lipidflow, R/get_lipid_absolute_quantification.R).
# ---------------------------------------------------------------------------
.lfs_default_match_item_pos <- function() {
  list(
    "Cer"  = "d18:1 (d7)-15:0 Cer",
    "ChE"  = c("18:1(d7) Chol Ester", "Cholesterol (d7)"),
    "Chol" = "Cholesterol (d7)",
    "DG"   = "15:0-18:1(d7) DAG",
    "LPC"  = "18:1(d7) Lyso PC",
    "LPE"  = "18:1(d7) Lyso PE",
    "MG"   = "18:1 (d7) MG",
    "PA"   = "15:0-18:1(d7) PA (Na Salt)",
    "PC"   = "15:0-18:1(d7) PC",
    "PE"   = "15:0-18:1(d7) PE",
    "PG"   = "15:0-18:1(d7) PG (Na Salt)",
    "PI"   = "15:0-18:1(d7) PI (NH4 Salt)",
    "PPE"  = "C18(Plasm)-18:1(d9) PE",
    "PS"   = "15:0-18:1(d7) PS (Na Salt)",
    "SM"   = "d18:1-18:1(d9) SM",
    "TG"   = "15:0-18:1(d7)-15:0 TAG"
  )
}

.lfs_default_match_item_neg <- function() {
  list(
    "Cer"  = "d18:1 (d7)-15:0 Cer",
    "Chol" = "Cholesterol (d7)",
    "ChE"  = c("18:1(d7) Chol Ester", "Cholesterol (d7)"),
    "LPC"  = "18:1(d7) Lyso PC",
    "LPE"  = "18:1(d7) Lyso PE",
    "PC"   = "15:0-18:1(d7) PC",
    "PE"   = "15:0-18:1(d7) PE",
    "PG"   = "15:0-18:1(d7) PG (Na Salt)",
    "PI"   = "15:0-18:1(d7) PI (NH4 Salt)",
    "PPE"  = "C18(Plasm)-18:1(d9) PE",
    "PS"   = "15:0-18:1(d7) PS (Na Salt)",
    "SM"   = "d18:1-18:1(d9) SM"
  )
}

# ---------------------------------------------------------------------------
# Extract the leading alphabetic lipid-class prefix from a lipid name, e.g.
# "PC(15:0_18:1)" -> "PC", "TG(52:2)" -> "TG", "Cer(d18:1/24:0)" -> "Cer".
# Returns NA for names with no leading letters (garbage/empty input) rather
# than erroring - a single unparsable name shouldn't abort the whole table.
# Never mutates its input.
# ---------------------------------------------------------------------------
.lfs_parse_lipid_class <- function(lipid_name) {
  lipid_name <- as.character(lipid_name)
  out <- rep(NA_character_, length(lipid_name))
  trimmed <- trimws(lipid_name)
  has_prefix <- !is.na(lipid_name) & nzchar(trimmed) & grepl("^[A-Za-z]+", trimmed)
  out[has_prefix] <- sub("^([A-Za-z]+).*$", "\\1", trimmed[has_prefix])
  out
}

# ---------------------------------------------------------------------------
# Auto-infer a Class -> IS name(s) mapping by matching each lipid Class token
# against the Internal Standard names actually present in Y_IS_opt/is_table -
# ported from the teammate's V5 script's infer_class_to_is(), adopted per
# direct agreement in place of .lfs_default_match_item_pos()/_neg()'s static
# 16-class table, which silently matched nothing for any custom Internal
# Standard named outside that fixed list.
#
# Lyso classes (LPC/LPE/LPI/LPG/LPA/LPS) are matched FIRST against a
# "Lyso PC"-style alias, so a Lyso PC Internal Standard is never also swept
# into the plain "PC" bucket by the generic match that runs after - same
# rationale, same order as V5. The generic match itself is WORD-BOUNDARY
# regex, not substring - "PE" does not match inside an IS name containing
# "PPE" (the boundary requires a non-alphanumeric or string edge on both
# sides), so processing order between classes doesn't change the result.
# is_names goes through .lfs_normalize_ws() (utils_import.R), not plain
# trimws() - lipidflow's own bundled demo IS_information.xlsx has trailing
# U+00A0 non-breaking spaces on some names, confirmed by inspecting the real
# file, which trimws() alone does not strip and would silently break the
# match against an otherwise-identical name.
#
# A Class with zero matching IS gets an empty character(0) entry (not
# dropped, not NA) - .lfs_absolute_quant_from_tables()'s caller
# (lipidflow::cal_abs(), via get_absolute_quantification()) treats an empty
# candidate vector as "no match" the same way it treats a Class simply
# absent from match_item - see this file's own header for what happens
# next (the feature is dropped, not kept with NA - lipidflow's own real
# behavior, kept as-is). Never mutates its inputs.
#
# KNOWN GAP, confirmed against lipidflow's own bundled default IS names (not
# hypothetical): word-boundary matching alone misses "TG" against an IS name
# spelled "...TAG" (triacylglycerol - the alternate abbreviation
# .lfs_default_match_item_pos()'s own default "TG" entry uses:
# "15:0-18:1(d7)-15:0 TAG"), and the same for "DG"/"...DAG". Added as
# aliases below, same mechanism as the Lyso classes. "ChE" (vs an IS name
# reading "...Chol Ester") and "Chol" (a true PREFIX of "Cholesterol", which
# the boundary regex deliberately does not treat as a whole-word match) are
# NOT aliased here - guessing a broader rule for those risks false
# positives elsewhere; an explicit match_item override
# (.lfs_default_match_item_pos()/_neg(), or a hand-built list) still covers
# them if needed.
# ---------------------------------------------------------------------------
.lfs_infer_class_to_is <- function(classes, is_names) {
  classes <- sort(unique(classes[!is.na(classes) & nzchar(classes)]))
  is_names <- .lfs_normalize_ws(as.character(is_names))
  is_class <- rep(NA_character_, length(is_names))

  known_aliases <- c(
    LPC = "LYSO[[:space:]-]*PC", LPE = "LYSO[[:space:]-]*PE",
    LPI = "LYSO[[:space:]-]*PI", LPG = "LYSO[[:space:]-]*PG",
    LPA = "LYSO[[:space:]-]*PA", LPS = "LYSO[[:space:]-]*PS",
    TG = "TAG", DG = "DAG", MG = "MAG"
  )
  for (class_name in intersect(names(known_aliases), classes)) {
    pattern <- paste0("(^|[^[:alnum:]])", known_aliases[[class_name]], "($|[^[:alnum:]])")
    is_class[is.na(is_class) & grepl(pattern, is_names, ignore.case = TRUE, perl = TRUE)] <- class_name
  }
  for (class_name in classes) {
    pattern <- paste0("(^|[^[:alnum:]])", class_name, "($|[^[:alnum:]])")
    is_class[is.na(is_class) & grepl(pattern, is_names, ignore.case = TRUE, perl = TRUE)] <- class_name
  }

  # which(), not a direct logical-vector index - is_class has real NA entries
  # (any IS name that matched no class at all), and `is_names[is_class ==
  # class_name]` would index with a logical vector containing NA at those
  # positions, silently inserting a stray NA_character_ into the result
  # instead of skipping it. which() drops NA positions safely.
  mapping <- lapply(classes, function(class_name) unique(is_names[which(is_class == class_name)]))
  names(mapping) <- classes
  mapping
}

# ---------------------------------------------------------------------------
# Build lipidflow::get_absolute_quantification()'s 4 inputs from tables
# already produced by earlier steps, call it, and reshape its result into 1
# flat data.frame - see this file's header for the full rationale.
#
#   peak_table       - Step 1's output: needs variable_id, mz, rt (found via
#                       .lfs_find_col(), so a re-uploaded CSV with the same
#                       column names works identically to a live run), plus
#                       >=1 further column - every column that isn't one of
#                       those 3 is a sample's Peak_Area column.
#   annotation_table  - Step 2's output: needs variable_id + a lipid-name
#                       column. .lfs_best_candidate_per_feature() reduces a
#                       multi-candidate table (candidate.num > 1) to 1 row/
#                       feature first - a caller that already reduced it can
#                       pass either shape in.
#   y_is_opt          - Small Tools -> Peak Extraction's Y_IS_opt (or an
#                       uploaded equivalent CSV): needs IS_Name, Peak_Area,
#                       Measured_RT.
#   is_table          - Data Import's Internal Standard table: needs name,
#                       ug_ml, um.
#   match_item        - Class -> IS name(s) list.
#
# A feature present in annotation_table but absent from peak_table (name
# mismatch between 2 independently-uploaded files) is dropped BEFORE calling
# lipidflow - it would otherwise carry an NA rt into cal_abs(), which crashes
# on `if (max(lipid_tag$rt) < 60)` when rt is NA (confirmed by reading its
# source - not a graceful path).
#
# Returns list(table, n_input, n_quantified) - n_input is how many annotated
# features were offered to lipidflow, n_quantified is how many rows actually
# came back (cal_abs() drops any whose Class has no match_item entry, per
# its own real behavior - see header). mod_quantification.R shows both so a
# gap between them is visible, not a silent disappearance.
# ---------------------------------------------------------------------------
.lfs_absolute_quant_from_tables <- function(peak_table, annotation_table, y_is_opt, is_table, match_item = NULL) {
  if (!is.data.frame(peak_table)) stop(".lfs_absolute_quant_from_tables: 'peak_table' must be a data.frame.")
  if (!is.data.frame(annotation_table)) stop(".lfs_absolute_quant_from_tables: 'annotation_table' must be a data.frame.")
  if (!is.data.frame(y_is_opt)) stop(".lfs_absolute_quant_from_tables: 'y_is_opt' must be a data.frame.")
  if (!is.data.frame(is_table)) stop(".lfs_absolute_quant_from_tables: 'is_table' must be a data.frame.")
  if (!is.null(match_item) && (!is.list(match_item) || length(match_item) == 0)) {
    stop(".lfs_absolute_quant_from_tables: 'match_item' must be NULL (auto-infer) or a non-empty named list.")
  }

  pt_id <- .lfs_find_col(peak_table, c("variable_id", "Variable.ID", "variable", "variableID"))
  pt_mz <- .lfs_find_col(peak_table, c("mz", "MZ", "mass_to_charge"))
  pt_rt <- .lfs_find_col(peak_table, c("rt", "RT", "retention_time", "retention time"))
  if (is.na(pt_id)) stop(".lfs_absolute_quant_from_tables: 'peak_table' has no recognizable variable_id column.")
  if (is.na(pt_rt)) stop(".lfs_absolute_quant_from_tables: 'peak_table' has no recognizable rt column.")
  sample_cols <- setdiff(colnames(peak_table), c(pt_id, pt_mz, pt_rt))
  if (length(sample_cols) == 0) stop(".lfs_absolute_quant_from_tables: 'peak_table' has no sample (Peak_Area) columns.")

  ann_id <- .lfs_find_col(annotation_table, c("variable_id", "Variable.ID", "variable", "variableID"))
  ann_name <- .lfs_find_col(annotation_table, c("Compound.name", "compound_name", "name", "Name"))
  if (is.na(ann_id) || is.na(ann_name)) {
    stop(".lfs_absolute_quant_from_tables: 'annotation_table' needs a variable_id and a lipid-name column.")
  }

  is_name_col <- .lfs_find_col(y_is_opt, c("IS_Name", "is_name"))
  is_area_col <- .lfs_find_col(y_is_opt, c("Peak_Area", "peak_area"))
  is_rt_col <- .lfs_find_col(y_is_opt, c("Measured_RT", "measured_rt", "rt"))
  if (is.na(is_name_col) || is.na(is_area_col) || is.na(is_rt_col)) {
    stop(".lfs_absolute_quant_from_tables: 'y_is_opt' needs IS_Name, Peak_Area and Measured_RT columns.")
  }

  ist_name_col <- .lfs_find_col(is_table, c("name", "Name"))
  ist_ug_col <- .lfs_find_col(is_table, c("ug_ml"))
  ist_um_col <- .lfs_find_col(is_table, c("um"))
  if (is.na(ist_name_col) || is.na(ist_ug_col) || is.na(ist_um_col)) {
    stop(".lfs_absolute_quant_from_tables: 'is_table' needs name, ug_ml and um columns.")
  }

  ann <- .lfs_best_candidate_per_feature(annotation_table, feature_id_col = ann_id)

  # ---- lipid_quantification_table: peak_name, Class, rt, + 1 col/sample ----
  ann_small <- data.frame(variable_id = as.character(ann[[ann_id]]),
                           Lipid_Name = as.character(ann[[ann_name]]),
                           stringsAsFactors = FALSE)
  pt_small <- peak_table[, c(pt_id, pt_rt, sample_cols), drop = FALSE]
  names(pt_small)[names(pt_small) == pt_id] <- "variable_id"
  names(pt_small)[names(pt_small) == pt_rt] <- "rt"
  pt_small$variable_id <- as.character(pt_small$variable_id)

  # Inner join on purpose (not all.x) - a feature annotated but absent from
  # peak_table has no rt to give cal_abs(), which is required, not optional
  # (see this function's own header).
  n_input <- nrow(ann_small)
  lipid_merged <- merge(ann_small, pt_small, by = "variable_id", sort = FALSE)
  lipid_merged$Class <- .lfs_parse_lipid_class(lipid_merged$Lipid_Name)
  # peak_name must be unique (lipidflow uses it as rownames) - 2 features
  # sharing the same annotated compound name is possible, variable_id never
  # collides.
  lipid_merged$peak_name <- paste(lipid_merged$Lipid_Name, lipid_merged$variable_id, sep = "__")
  lipid_quantification_table <- lipid_merged[, c("peak_name", "variable_id", "Lipid_Name", "Class", "rt", sample_cols),
                                              drop = FALSE]

  if (nrow(lipid_quantification_table) == 0) {
    return(list(table = lipid_quantification_table[, character(0), drop = FALSE][0, , drop = FALSE],
                n_input = n_input, n_quantified = 0L,
                raw_lipid_table = lipid_quantification_table, raw_is_table = NULL, match_item = NULL))
  }

  # ---- is_quantification_table: name, ug_ml, um, rt, + 1 col/sample -------
  is_df <- data.frame(
    name = as.character(y_is_opt[[is_name_col]]),
    rt = suppressWarnings(as.numeric(y_is_opt[[is_rt_col]])),
    Peak_Area = suppressWarnings(as.numeric(y_is_opt[[is_area_col]])),
    stringsAsFactors = FALSE
  )
  ist_small <- data.frame(
    name = as.character(is_table[[ist_name_col]]),
    ug_ml = suppressWarnings(as.numeric(is_table[[ist_ug_col]])),
    um = suppressWarnings(as.numeric(is_table[[ist_um_col]])),
    stringsAsFactors = FALSE
  )
  is_df <- merge(is_df, ist_small, by = "name", all.x = TRUE, sort = FALSE)
  # Y_IS_opt currently holds ONE QC-derived Peak_Area per IS - broadcast that
  # same value to every sample column, since there's no per-sample
  # measurement yet (see this file's header). Once Peak Extraction is run
  # per-sample instead of on a single QC file, y_is_opt would carry real
  # per-sample values here instead and this loop needs no change at all.
  for (col in sample_cols) is_df[[col]] <- is_df$Peak_Area
  is_quantification_table <- is_df[, c("name", "ug_ml", "um", "rt", sample_cols), drop = FALSE]

  # match_item = NULL (the default) auto-infers Class -> IS from the names
  # actually present, per direct agreement (adopts the teammate's V5 script's
  # approach) - see .lfs_infer_class_to_is()'s own header. Passing an
  # explicit match_item (e.g. .lfs_default_match_item_pos()/_neg(), or a
  # hand-built override) still works exactly as before.
  if (is.null(match_item)) {
    match_item <- .lfs_infer_class_to_is(lipid_quantification_table$Class, is_quantification_table$name)
  }

  # Defensive pre-check for a real bug in lipidflow 0.0.1's own cal_abs():
  # its internal `for (i in 1:nrow(lipid_tag))` uses R's 1:n idiom, which for
  # n = 0 evaluates to c(1, 0) (NOT integer(0)) - so if literally no IS name
  # in Y_IS_opt overlaps match_item at all, cal_abs() would try to index row
  # 1/0 of an already-empty table and crash with a confusing subscript error
  # instead of returning an empty result. Caught here with a clear message
  # instead - confirmed by reading cal_abs()'s real source, not guessed.
  if (length(intersect(is_quantification_table$name, unique(unlist(match_item)))) == 0) {
    stop("No Internal Standard name in Y_IS_opt matches any name in match_item - nothing can be quantified. ",
         "Check that Y_IS_opt's IS_Name values match the Class-to-IS table's names.")
  }

  sample_info <- data.frame(sample.name = sample_cols, stringsAsFactors = FALSE)

  quant_path <- tempfile("lfs_absquant_")
  dir.create(quant_path)
  raw <- lipidflow::get_absolute_quantification(
    path = quant_path,
    is_quantification_table = is_quantification_table,
    lipid_quantification_table = lipid_quantification_table,
    sample_info = sample_info,
    match_item = match_item
  )

  ug <- raw$express_data_abs_ug_ml
  um <- raw$express_data_abs_um
  colnames(ug) <- paste0(colnames(ug), "_ug_ml")
  colnames(um) <- paste0(colnames(um), "_um")
  table_out <- cbind(raw$variable_info_abs, ug, um)
  rownames(table_out) <- NULL

  # raw_lipid_table/raw_is_table/match_item - kept alongside the final ratio
  # table (not thrown away) so a caller building the lipidflow-style
  # is/raw/final 3-panel intensity_plot (see .lfs_write_intensity_plot_pdfs())
  # can look up each feature's PRE-ratio Peak_Area (lipid + matched Internal
  # Standard) without re-deriving them from peak_table/y_is_opt a 2nd time.
  # match_item is also returned since cal_abs() itself does NOT report back
  # which IS name it picked per feature (confirmed by reading its source -
  # variable_info_abs is just the original lipid_tag, unchanged) - a caller
  # needing that has to redo cal_abs()'s own rt-closest tie-break itself
  # (see .lfs_match_is_for_feature()), for which it needs this same
  # match_item (already filtered to Classes that survived above).
  list(table = table_out, n_input = n_input, n_quantified = nrow(table_out),
       raw_lipid_table = lipid_quantification_table, raw_is_table = is_quantification_table,
       match_item = match_item)
}

# ---------------------------------------------------------------------------
# Class-level reporting on top of .lfs_absolute_quant_from_tables()'s own
# per-feature output - the same 2 extra views
# lipidflow::get_lipid_absolute_quantification() writes to disk
# (lipid_data_class_ug_ml/um.xlsx, lipid_data_*_um_per.xlsx), reproduced here
# as a pure function on the table we ALREADY have instead of calling that
# function (which needs raw sample files + a fixed on-disk file layout - see
# project discussion). No package call, no raw data - group/sum + percentage
# arithmetic only.
#
# Percent composition is mol% (um-basis only, not ug_ml) - the standard
# lipidomics convention - but CONFIRMED against real
# get_lipid_absolute_quantification() output (a teammate shared its actual
# plot_ug.pdf AND plot_um.pdf: both are % composition, stacked to 1.0/100%)
# that the ug_ml basis gets its own % view too, even though it has no
# separate "..._ug_ml_per.xlsx" data file - the plot computes it on the fly.
# Percentages here are 0-100 (a real percentage, not a 0-1 fraction) -
# confirmed by back-calculating a real um_per.xlsx value the teammate shared
# (ChE/D25_1: 79.1094842 um / grand-total 100.795 x 100 = 78.487, matching
# the sheet's 78.48548481) - not guessed.
#
# Each feature's/class's % is of the GRAND TOTAL (that unit, that sample)
# across every classified feature - so summing every feature's % in a
# sample reproduces that class's %, and summing every class's % reproduces
# 100%.
#
# Input: `quant_table` - the $table from .lfs_absolute_quant_from_tables(),
# needs Class plus >=1 pair of "<sample>_ug_ml"/"<sample>_um" columns.
# Returns list(class_ug_ml, class_um, feature_pct_ug_ml, feature_pct_um,
# class_pct_ug_ml, class_pct_um) - 6 data.frames, each downloadable as its
# own CSV from mod_quantification.R. A sample column whose grand total is 0
# (or the table is empty) gets NA percentages for that column, not
# division-by-zero/NaN. Never mutates its input.
# ---------------------------------------------------------------------------
.lfs_lipid_class_summary <- function(quant_table) {
  if (!is.data.frame(quant_table)) stop(".lfs_lipid_class_summary: 'quant_table' must be a data.frame.")
  if (!"Class" %in% colnames(quant_table)) stop(".lfs_lipid_class_summary: 'quant_table' has no Class column.")
  ug_cols <- grep("_ug_ml$", colnames(quant_table), value = TRUE)
  um_cols <- grep("_um$", colnames(quant_table), value = TRUE)
  if (length(ug_cols) == 0 || length(um_cols) == 0) {
    stop(".lfs_lipid_class_summary: 'quant_table' has no _ug_ml/_um sample columns - run .lfs_absolute_quant_from_tables() first.")
  }
  id_cols <- intersect(c("peak_name", "variable_id", "Lipid_Name", "Class"), colnames(quant_table))

  sum_by_class <- function(cols) {
    if (nrow(quant_table) == 0) {
      empty <- as.data.frame(matrix(numeric(0), ncol = length(cols), dimnames = list(NULL, cols)))
      return(cbind(Class = character(0), empty))
    }
    stats::aggregate(quant_table[, cols, drop = FALSE], by = list(Class = quant_table$Class),
                      FUN = function(x) sum(x, na.rm = TRUE))
  }
  class_ug_ml <- sum_by_class(ug_cols)
  class_um <- sum_by_class(um_cols)

  grand_total <- function(col) {
    if (nrow(quant_table) == 0) return(0)
    sum(quant_table[[col]], na.rm = TRUE)
  }

  feature_pct_for <- function(cols) {
    out <- quant_table[, id_cols, drop = FALSE]
    for (col in cols) {
      total <- grand_total(col)
      out[[paste0(col, "_pct")]] <- if (total > 0) quant_table[[col]] / total * 100 else rep(NA_real_, nrow(quant_table))
    }
    out
  }
  class_pct_for <- function(cols, class_sums) {
    out <- class_sums
    for (col in cols) {
      total <- grand_total(col)
      out[[col]] <- if (total > 0) out[[col]] / total * 100 else rep(NA_real_, nrow(out))
    }
    names(out)[match(cols, names(out))] <- paste0(cols, "_pct")
    out
  }

  list(class_ug_ml = class_ug_ml, class_um = class_um,
       feature_pct_ug_ml = feature_pct_for(ug_cols), feature_pct_um = feature_pct_for(um_cols),
       class_pct_ug_ml = class_pct_for(ug_cols, class_ug_ml), class_pct_um = class_pct_for(um_cols, class_um))
}

# ---------------------------------------------------------------------------
# Reproduces the CORE IDEA of lipidflow:::combine_pos_neg_quantification()
# (real source read via body() - not guessed) - only used for the "Combined
# (POS+NEG)" Class Summary view, per direct agreement (feature-level
# quant_result_pos/neg and the Feature Detail chart stay per-side only,
# untouched - real lipidflow's own intensity_plot/ is per-side too).
#
# WHY a merge step exists at all: the SAME physical lipid can ionize in
# BOTH polarities (PC/PE/PS/PI/PG routinely show real signal in either
# mode) - summing "total PC" from POS + NEG separately would double-count
# that lipid. Real lipidflow: rbind(pos, neg) rows, then for any Lipid_Name
# present in both, keep ONLY the row with the higher mean.int (raw MS
# intensity) and drop the other entirely - never sums/averages the two.
#
# DIVERGENCE (documented, not a bug): this app's quant_result tables don't
# carry mean.int (raw MS intensity) through to this stage - the tie-break
# proxy used here is each row's own mean concentration across samples (ug/
# mL basis), the closest available stand-in, monotonic with signal
# strength in virtually every real case. A blank/NA Lipid_Name is never
# deduplicated against anything (can't judge "same lipid" without a name).
#
# Input: 2 quant_result-shaped data.frames (.lfs_absolute_quant_from_
# tables()'s own output shape) - must share the identical set of sample
# columns (same physical samples run in both polarities, as expected for
# one experiment). Output: 1 data.frame, same columns, feature-level -
# feeds straight into .lfs_lipid_class_summary() exactly like a single-side
# table would. Never mutates its inputs.
# ---------------------------------------------------------------------------
.lfs_combine_pos_neg_quantification <- function(quant_pos, quant_neg) {
  if (!is.data.frame(quant_pos) || !is.data.frame(quant_neg)) {
    stop(".lfs_combine_pos_neg_quantification: both 'quant_pos' and 'quant_neg' must be data.frames.")
  }
  if (!"Class" %in% colnames(quant_pos) || !"Class" %in% colnames(quant_neg)) {
    stop(".lfs_combine_pos_neg_quantification: both tables need a Class column.")
  }
  if (!"Lipid_Name" %in% colnames(quant_pos) || !"Lipid_Name" %in% colnames(quant_neg)) {
    stop(".lfs_combine_pos_neg_quantification: both tables need a Lipid_Name column.")
  }
  id_cols <- intersect(c("peak_name", "variable_id", "Lipid_Name", "Class"), colnames(quant_pos))
  sample_cols <- setdiff(colnames(quant_pos), id_cols)
  if (!setequal(sample_cols, setdiff(colnames(quant_neg), id_cols))) {
    stop(".lfs_combine_pos_neg_quantification: POS and NEG tables must share the same sample columns (same samples run in both polarities).")
  }
  ug_cols <- grep("_ug_ml$", sample_cols, value = TRUE)
  if (length(ug_cols) == 0) {
    stop(".lfs_combine_pos_neg_quantification: no _ug_ml sample columns found - run .lfs_absolute_quant_from_tables() first.")
  }

  combined <- rbind(quant_pos[, c(id_cols, sample_cols), drop = FALSE],
                     quant_neg[, c(id_cols, sample_cols), drop = FALSE])
  rownames(combined) <- NULL
  if (nrow(combined) == 0) return(combined)

  signal <- rowMeans(as.matrix(combined[, ug_cols, drop = FALSE]), na.rm = TRUE)
  signal[is.nan(signal)] <- 0
  has_name <- !is.na(combined$Lipid_Name) & nzchar(trimws(combined$Lipid_Name))

  keep <- rep(TRUE, nrow(combined))
  dup_groups <- split(which(has_name), combined$Lipid_Name[has_name])
  for (idx in dup_groups) {
    if (length(idx) > 1) {
      best <- idx[which.max(signal[idx])[1]]
      keep[setdiff(idx, best)] <- FALSE
    }
  }
  combined[keep, , drop = FALSE]
}

# ---------------------------------------------------------------------------
# Class composition chart - the auto-generated plot lipidflow::get_lipid_
# absolute_quantification() writes as plot_um.pdf/class_plot/, reproduced
# here as a live plotly chart on top of .lfs_lipid_class_summary()'s own
# output (no raw files, no PDF - fits a web app better than a saved file).
#
# Color assignment is a FIXED, canonical Class -> hue mapping (never re-
# ranked by whatever happens to be biggest in the CURRENT sample set) -
# "color follows the entity, never its rank": switching between POS/NEG/
# Combined, or re-running with a different sample set, must not repaint a
# Class that was already on screen.
#
# Palette is a designer soft-pastel gradient (coral -> orange -> olive ->
# green -> teal -> sky blue -> periwinkle -> magenta -> hot pink), chosen to
# match a reference figure the user shared rather than ggplot2's default
# full-saturation hue wheel. Built by Lab-space interpolation between a
# handful of hand-picked "key" stops (colorRampPalette(..., space = "Lab")
# gives a perceptually smooth ramp - straight RGB interpolation between
# distant hues muddies through grey mid-ramp). Still a FIXED, canonical
# Class -> color mapping assigned in the same alphabetical order as before
# (one slot per canonical Class name below) - "color follows the entity,
# never its rank": switching between POS/NEG/Combined, or re-running with a
# different sample set, must not repaint a Class that was already on
# screen. Any Class name outside this canonical set (unexpected/typo'd
# label) still folds into a single grey "Other" rather than growing the
# ramp further.
# ---------------------------------------------------------------------------
.LFS_CLASS_COLOR_ORDER <- c("Cer", "ChE", "Chol", "DG", "LPC", "LPE", "MG", "PA",
                            "PC", "PE", "PG", "PI", "PPE", "PS", "SM", "TG")
.LFS_CLASS_OTHER_HEX <- "#898781"
.LFS_CLASS_GRADIENT_STOPS <- c("#F2766A", "#F2A73A", "#C7C13E", "#4FB55B", "#1FA98F",
                               "#2EA0DE", "#8B7FD8", "#C46FC0", "#E8578E")

.lfs_class_color_map <- function() {
  n <- length(.LFS_CLASS_COLOR_ORDER)
  ramp <- grDevices::colorRampPalette(.LFS_CLASS_GRADIENT_STOPS, space = "Lab")(n)
  stats::setNames(c(ramp, .LFS_CLASS_OTHER_HEX), c(.LFS_CLASS_COLOR_ORDER, "Other"))
}

# ---------------------------------------------------------------------------
# Reshape .lfs_lipid_class_summary()'s $class_pct_um / $class_pct_ug_ml (1
# row/Class, 1 column/sample, columns suffixed "_um_pct" or "_ug_ml_pct")
# into long form (sample, Class, pct) for a stacked bar chart - folding any
# Class outside .LFS_CLASS_COLOR_ORDER into "Other", SUMMED per sample (not
# left as separate same-labeled rows, which would draw multiple redundant
# "Other" segments in one bar). Class is returned as a factor with levels in
# the fixed canonical order (+ "Other" last) so ggplot2's stacking order
# matches the legend order and never depends on which classes happen to be
# present. Works for EITHER basis - real lipidflow output (plot_ug.pdf AND
# plot_um.pdf, both % composition) confirms both bases get their own %
# view, so the suffix to strip is detected from the column names rather
# than hardcoded to one unit. Never mutates its input.
# ---------------------------------------------------------------------------
.lfs_class_composition_long <- function(class_pct_table) {
  if (!is.data.frame(class_pct_table)) stop(".lfs_class_composition_long: 'class_pct_table' must be a data.frame.")
  if (!"Class" %in% colnames(class_pct_table)) stop(".lfs_class_composition_long: 'class_pct_table' has no Class column.")
  sample_cols <- setdiff(colnames(class_pct_table), "Class")
  if (length(sample_cols) == 0) stop(".lfs_class_composition_long: 'class_pct_table' has no sample columns.")

  color_map <- .lfs_class_color_map()
  levels_order <- names(color_map)
  empty_out <- data.frame(sample = character(), Class = factor(character(), levels = levels_order),
                          pct = numeric(), stringsAsFactors = FALSE)
  if (nrow(class_pct_table) == 0) return(empty_out)

  display_class <- ifelse(class_pct_table$Class %in% .LFS_CLASS_COLOR_ORDER, class_pct_table$Class, "Other")

  long <- do.call(rbind, lapply(sample_cols, function(col) {
    sample_name <- sub("_ug_ml_pct$", "", sub("_um_pct$", "", col))
    data.frame(sample = sample_name, Class = display_class,
               pct = suppressWarnings(as.numeric(class_pct_table[[col]])), stringsAsFactors = FALSE)
  }))
  agg <- stats::aggregate(pct ~ sample + Class, data = long, FUN = function(x) sum(x, na.rm = TRUE))
  agg$Class <- factor(agg$Class, levels = levels_order)
  agg[order(agg$sample, agg$Class), , drop = FALSE]
}

# ---------------------------------------------------------------------------
# The chart itself - stacked bar (% composition, 1 bar/sample) built with
# ggplot2 then made interactive via plotly::ggplotly() (per-segment hover
# tooltip - see dataviz skill's interaction.md: a bar chart ships hover by
# default). fill = a fixed hex per Class (.lfs_class_color_map()), not
# ggplot2's own default hue generator, so color stays tied to the Class
# identity rather than whatever order factor levels happen to sort in.
# No stroke on the segments themselves - a per-segment border (even a
# near-white one) reads as a seam between adjacent Classes stacked in the
# same bar, breaking the continuous gradient look the palette is meant to
# give. Separation between bars/samples comes from `width = 0.68` alone
# (each bar narrower than its slot) rather than from an outline. `unit_
# label` names which basis (ug/mL or uM) the % is computed on, matching
# real lipidflow's separate plot_ug.pdf/plot_um.pdf.
# ---------------------------------------------------------------------------

# Pulled out of .lfs_class_composition_plot() below so a static-export caller
# (.lfs_write_composition_pdf(), used for the standalone plot_ug.pdf/
# plot_um.pdf export - see that function's header) can ggsave() the plain
# ggplot object directly, without going through plotly::ggplotly() first
# (which drops the `text` tooltip aesthetic into a form ggsave can't use
# meaningfully anyway). Behavior of .lfs_class_composition_plot() itself is
# unchanged - still builds this ggplot, then wraps it in ggplotly().
.lfs_class_composition_ggplot <- function(class_pct_table, unit_label = "") {
  data <- .lfs_class_composition_long(class_pct_table)
  color_map <- .lfs_class_color_map()
  y_lab <- if (nzchar(unit_label)) sprintf("Composition (%% of %s)", unit_label) else "Composition (%)"
  ggplot2::ggplot(data, ggplot2::aes(x = sample, y = pct, fill = Class,
                                     text = sprintf("%s\n%s: %.1f%%", sample, Class, pct))) +
    ggplot2::geom_col(width = 0.68) +
    ggplot2::scale_fill_manual(values = color_map, drop = TRUE, name = "Class") +
    ggplot2::scale_y_continuous(expand = ggplot2::expansion(mult = c(0, 0.02))) +
    ggplot2::labs(x = NULL, y = y_lab) +
    ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(color = "#e1e0d9", linewidth = 0.4),
      axis.line.x = ggplot2::element_line(color = "#c3c2b7", linewidth = 0.4),
      axis.text.x = ggplot2::element_text(angle = 45, hjust = 1, color = "#52514e"),
      axis.text.y = ggplot2::element_text(color = "#898781"),
      axis.title.y = ggplot2::element_text(color = "#52514e"),
      legend.title = ggplot2::element_text(color = "#52514e")
    )
}

.lfs_class_composition_plot <- function(class_pct_table, unit_label = "") {
  p <- .lfs_class_composition_ggplot(class_pct_table, unit_label = unit_label)
  fig <- plotly::ggplotly(p, tooltip = "text")
  plotly::layout(fig, legend = list(title = list(text = "Class")))
}

# ---------------------------------------------------------------------------
# Class MAGNITUDE chart - the 2nd auto-generated view
# lipidflow::get_lipid_absolute_quantification() writes (plot_ug.pdf/
# plot_um.pdf + class_plot/, one file per class). Unlike the composition
# chart above (mol% - a part-of-whole, stacks to 100%, so identity color per
# Class is the point), raw concentration totals differ by orders of
# magnitude between classes (TG total is routinely 10-100x PC total) -
# stacking or a shared y-scale would visually erase the smaller classes.
# Small multiples (facet_wrap by Class, free y-scale) is the correct form
# for that (dataviz skill's choosing-a-form.md: many magnitudes, each on its
# own footing) - one panel per Class IS what class_plot/ was doing with
# separate files; this is the same idea as ONE scrollable chart instead of
# N static ones, more appropriate for a web app.
#
# A single bar series needs no categorical legend at all (dataviz skill:
# "a single series needs no legend box") - the facet title already names
# the Class, so this uses ONE consistent color (the sequential-hue default,
# step 450) rather than the categorical ramp, which stays reserved for
# actual multi-series identity (the composition chart above).
# ---------------------------------------------------------------------------
.LFS_MAGNITUDE_HEX <- "#2a78d6"

.lfs_class_magnitude_long <- function(class_table) {
  if (!is.data.frame(class_table)) stop(".lfs_class_magnitude_long: 'class_table' must be a data.frame.")
  if (!"Class" %in% colnames(class_table)) stop(".lfs_class_magnitude_long: 'class_table' has no Class column.")
  sample_cols <- setdiff(colnames(class_table), "Class")
  if (length(sample_cols) == 0) stop(".lfs_class_magnitude_long: 'class_table' has no sample columns.")
  if (nrow(class_table) == 0) return(data.frame(Class = character(), sample = character(), value = numeric()))

  do.call(rbind, lapply(sample_cols, function(col) {
    data.frame(Class = class_table$Class, sample = col,
               value = suppressWarnings(as.numeric(class_table[[col]])), stringsAsFactors = FALSE)
  }))
}

.lfs_class_magnitude_plot <- function(class_table, unit_label = "") {
  data <- .lfs_class_magnitude_long(class_table)
  p <- ggplot2::ggplot(data, ggplot2::aes(x = sample, y = value,
                                          text = sprintf("%s\n%s: %s", sample, Class,
                                                         format(round(value, 2), big.mark = ",")))) +
    ggplot2::geom_col(fill = .LFS_MAGNITUDE_HEX, width = 0.68) +
    # facet_wrap() errors on a 0-row data.frame ("Faceting variables must
    # have at least one value") - only facet by Class when there's at least
    # 1 row to facet.
    { if (nrow(data) > 0) ggplot2::facet_wrap(~Class, scales = "free_y") } +
    ggplot2::labs(x = NULL, y = unit_label) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(color = "#e1e0d9", linewidth = 0.4),
      axis.line.x = ggplot2::element_line(color = "#c3c2b7", linewidth = 0.4),
      axis.text.x = ggplot2::element_text(angle = 45, hjust = 1, size = 7, color = "#52514e"),
      axis.text.y = ggplot2::element_text(size = 7, color = "#898781"),
      strip.text = ggplot2::element_text(color = "#0b0b0b", face = "bold"),
      strip.background = ggplot2::element_blank()
    )
  plotly::ggplotly(p, tooltip = "text")
}

# ---------------------------------------------------------------------------
# Feature-level detail - the interactive equivalent of
# get_lipid_absolute_quantification()'s intensity_plot/ (one static file per
# feature - hundreds for a real study, impractical to pre-render for a web
# UI). Instead: pick ONE feature (peak_name) on demand, show its
# concentration across every sample as a single-series bar chart - same
# "sequential hue, no legend needed" treatment as the magnitude chart above.
# ---------------------------------------------------------------------------
.lfs_feature_detail_long <- function(quant_table, peak_name, unit = c("um", "ug_ml")) {
  unit <- match.arg(unit)
  if (!is.data.frame(quant_table)) stop(".lfs_feature_detail_long: 'quant_table' must be a data.frame.")
  if (!"peak_name" %in% colnames(quant_table)) stop(".lfs_feature_detail_long: 'quant_table' has no peak_name column.")
  row <- quant_table[quant_table$peak_name == peak_name, , drop = FALSE]
  if (nrow(row) == 0) return(data.frame(sample = character(), value = numeric()))
  unit_cols <- grep(paste0("_", unit, "$"), colnames(row), value = TRUE)
  if (length(unit_cols) == 0) stop(".lfs_feature_detail_long: 'quant_table' has no '_", unit, "' sample columns.")
  data.frame(sample = sub(paste0("_", unit, "$"), "", unit_cols),
             value = suppressWarnings(as.numeric(row[1, unit_cols])), stringsAsFactors = FALSE)
}

.lfs_feature_detail_plot <- function(quant_table, peak_name, unit = c("um", "ug_ml")) {
  unit <- match.arg(unit)
  data <- .lfs_feature_detail_long(quant_table, peak_name, unit)
  unit_label <- if (unit == "um") "Concentration (uM)" else "Concentration (ug/mL)"
  p <- ggplot2::ggplot(data, ggplot2::aes(x = sample, y = value,
                                          text = sprintf("%s: %s", sample, format(round(value, 3), big.mark = ",")))) +
    ggplot2::geom_col(fill = .LFS_MAGNITUDE_HEX, width = 0.6) +
    ggplot2::labs(x = NULL, y = unit_label, title = peak_name) +
    ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(color = "#e1e0d9", linewidth = 0.4),
      axis.line.x = ggplot2::element_line(color = "#c3c2b7", linewidth = 0.4),
      axis.text.x = ggplot2::element_text(angle = 45, hjust = 1, color = "#52514e"),
      axis.text.y = ggplot2::element_text(color = "#898781"),
      plot.title = ggplot2::element_text(size = 12, color = "#0b0b0b")
    )
  plotly::ggplotly(p, tooltip = "text")
}

# ---------------------------------------------------------------------------
# STATIC EXPORT BUNDLE for "Download Results" - reproduces the real, on-disk
# lipidflow::get_lipid_absolute_quantification() output set (IS_info_table.xlsx,
# lipid_data_*.xlsx, lipid_data_class_*.xlsx, plot_ug.pdf/plot_um.pdf,
# class_plot/<Class>.pdf, intensity_plot/<Class>/<Lipid>.pdf - confirmed
# against the package's own vignette, not guessed) as real files on disk, on
# top of the Combined (POS+NEG) result - per direct agreement, this whole
# bundle is Combined-only (no separate POS/NEG copies), since that's the
# single result set a real lipidflow run would have produced.
#
# Everything below is pure/testable (writes only to an explicit out_dir
# given by the caller) except the two .lfs_write_*_pdfs() functions, which
# are unavoidably file-writing side effects (ggsave()) - kept as thin loops
# around the pure per-page plot builders above them so the plot CONTENT
# itself stays unit-testable without touching disk.
# ---------------------------------------------------------------------------

# Strip characters illegal in a Windows/Mac/Linux filename (: \ / * ? " < > |)
# down to "_" - lipidflow's own real intensity_plot/ output does exactly this
# (confirmed from the vignette: a lipid tagged "d15:1/15:0" becomes the file
# "Cer(d15_1_15_0).pdf", colons and slashes both replaced). Never returns an
# empty string (falls back to "unnamed") - an empty filename would silently
# collide with every other empty-name row instead of erroring visibly.
.lfs_sanitize_filename <- function(x) {
  x <- as.character(x)
  x <- gsub('[\\\\/:*?"<>|]', "_", x)
  x <- trimws(x)
  x[is.na(x) | !nzchar(x)] <- "unnamed"
  x
}

# Single-row-of-a-wide-table -> long (sample, value) - shared by the class_plot
# and intensity_plot page builders below (both plot "1 row, many sample
# columns" as a per-sample scatter). `sample_cols` may already be
# unit-suffixed; stripping that suffix is the CALLER's job (this function
# just reads whichever column names it's given).
.lfs_pivot_long_from_row <- function(row_df, sample_cols) {
  data.frame(sample = sample_cols,
             value = suppressWarnings(as.numeric(row_df[1, sample_cols, drop = TRUE])),
             stringsAsFactors = FALSE)
}

# Replicates lipidflow:::cal_abs()'s own per-feature Internal Standard
# tie-break (confirmed by reading its real source, not guessed): among the
# Class's candidate IS names that are ACTUALLY present in this side's
# raw_is_table, pick whichever's own rt is closest to the feature's rt. Needed
# here because cal_abs() itself never reports back which IS name it picked
# per feature (its return value's variable_info_abs is just the original
# lipid_tag, unchanged) - a caller building the "is" panel of intensity_plot
# has to redo this same tie-break independently. Returns NA_character_ (not
# an error) for a Class with no usable candidate - a page can still render
# its "is" panel as empty/flat in that case rather than the whole export
# failing over one feature.
.lfs_match_is_for_feature <- function(class_name, rt, match_item, raw_is_table) {
  if (is.null(match_item) || is.null(raw_is_table) || is.na(class_name) ||
      !class_name %in% names(match_item)) {
    return(NA_character_)
  }
  candidates <- match_item[[class_name]]
  candidates <- candidates[candidates %in% raw_is_table$name]
  if (length(candidates) == 0) return(NA_character_)
  if (length(candidates) == 1) return(candidates)
  is_rows <- raw_is_table[match(candidates, raw_is_table$name), , drop = FALSE]
  candidates[which.min(abs(rt - is_rows$rt))[1]]
}

# ---------------------------------------------------------------------------
# Combines 1 or 2 .lfs_absolute_quant_from_tables() results (POS/NEG, either
# may be NULL if that side wasn't run) into the single Combined dataset the
# whole export bundle is built from.
#
# Final table: unions POS+NEG rows exactly like .lfs_combine_pos_neg_
# quantification() (same "keep the higher mean-ug_ml-signal row per
# Lipid_Name, never sum" rule - re-implemented here rather than called,
# because this version also needs to carry `.side` through per kept row, to
# know which side's raw_is_table/match_item a feature's "is" panel should
# come from). Raw lipid table: filtered/reordered to match the SAME kept rows
# (by peak_name, which is globally unique - "Lipid_Name__variable_id", and
# variable_id is only unique within 1 side) - so final and raw stay row-
# aligned for the intensity_plot writer below. `raw_is_by_side`/
# `match_item_by_side` are kept per-side (not merged) since Y_IS_opt is
# measured separately per polarity - a POS feature's "is" panel must read
# POS's own IS measurement, never NEG's (see mod_quantification.R's own
# per-side Y_IS_opt handling for the same rule elsewhere in this app).
# ---------------------------------------------------------------------------
.lfs_build_quant_export_bundle <- function(full_pos, full_neg) {
  sides <- list(pos = full_pos, neg = full_neg)
  sides <- sides[!vapply(sides, is.null, logical(1))]
  if (length(sides) == 0) {
    stop(".lfs_build_quant_export_bundle: need at least one non-NULL result (full_pos/full_neg).")
  }

  final_tagged <- lapply(names(sides), function(s) {
    tbl <- sides[[s]]$table
    tbl$.side <- s
    tbl
  })
  raw_tagged <- lapply(names(sides), function(s) {
    tbl <- sides[[s]]$raw_lipid_table
    tbl$.side <- s
    tbl
  })
  combined_final <- do.call(rbind, final_tagged)
  rownames(combined_final) <- NULL

  if (length(sides) == 2) {
    ug_cols <- grep("_ug_ml$", colnames(combined_final), value = TRUE)
    signal <- rowMeans(as.matrix(combined_final[, ug_cols, drop = FALSE]), na.rm = TRUE)
    signal[is.nan(signal)] <- 0
    has_name <- !is.na(combined_final$Lipid_Name) & nzchar(trimws(combined_final$Lipid_Name))
    keep <- rep(TRUE, nrow(combined_final))
    dup_groups <- split(which(has_name), combined_final$Lipid_Name[has_name])
    for (idx in dup_groups) {
      if (length(idx) > 1) {
        best <- idx[which.max(signal[idx])[1]]
        keep[setdiff(idx, best)] <- FALSE
      }
    }
    combined_final <- combined_final[keep, , drop = FALSE]
  }

  combined_raw <- do.call(rbind, raw_tagged)
  rownames(combined_raw) <- NULL
  combined_raw <- combined_raw[match(combined_final$peak_name, combined_raw$peak_name), , drop = FALSE]
  rownames(combined_raw) <- NULL

  list(final = combined_final, raw_lipid = combined_raw,
       raw_is_by_side = lapply(sides, function(x) x$raw_is_table),
       match_item_by_side = lapply(sides, function(x) x$match_item))
}

# ---------------------------------------------------------------------------
# Splits the Combined final table's sample columns into 2 clean per-unit
# tables (id columns + 1 column/sample, unit suffix stripped from the sample
# names) - lipid_data_ug_ml.xlsx / lipid_data_um.xlsx. The 3rd feature-level
# file, lipid_data_um_per.xlsx, is .lfs_lipid_class_summary(final)$feature_pct_um
# directly (already the right shape) - not duplicated here.
# ---------------------------------------------------------------------------
.lfs_split_quant_table_by_unit <- function(final_table) {
  id_cols <- intersect(c("peak_name", "variable_id", "Lipid_Name", "Class", "rt"), colnames(final_table))
  ug_cols <- grep("_ug_ml$", colnames(final_table), value = TRUE)
  um_cols <- grep("(?<!_ug_ml)_um$", colnames(final_table), value = TRUE, perl = TRUE)

  ug_out <- final_table[, c(id_cols, ug_cols), drop = FALSE]
  names(ug_out)[match(ug_cols, names(ug_out))] <- sub("_ug_ml$", "", ug_cols)
  um_out <- final_table[, c(id_cols, um_cols), drop = FALSE]
  names(um_out)[match(um_cols, names(um_out))] <- sub("_um$", "", um_cols)
  list(ug_ml = ug_out, um = um_out)
}

# ---------------------------------------------------------------------------
# class_plot/<Class>.pdf - 1 static scatter (point + value label) per Class,
# X = sample, Y = that Class's total concentration - reproduces the real
# lipidflow vignette example (a "DG.pdf" scatter of 4 points, one per
# sample, each labeled with its value) exactly, per direct agreement -
# NOT the interactive facet/bar .lfs_class_magnitude_plot() above (that
# stays as-is for the on-screen "Class Magnitude" view; this is a separate,
# intentionally simpler static reproduction).
# ---------------------------------------------------------------------------
.lfs_class_scatter_plot <- function(data, title = "", y_label = "Intensity") {
  ggplot2::ggplot(data, ggplot2::aes(x = sample, y = value)) +
    ggplot2::geom_point(color = "#F2A73A", size = 3) +
    ggplot2::geom_text(ggplot2::aes(label = round(value, 4)), vjust = -0.9, size = 3.2, color = "#3d3c39") +
    ggplot2::scale_y_continuous(expand = ggplot2::expansion(mult = c(0.08, 0.2))) +
    ggplot2::labs(x = NULL, y = y_label, title = title) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(
      panel.grid.minor = ggplot2::element_blank(),
      axis.text.x = ggplot2::element_text(angle = 45, hjust = 1, color = "#52514e"),
      axis.text.y = ggplot2::element_text(color = "#898781"),
      plot.title = ggplot2::element_text(size = 12, face = "bold", color = "#0b0b0b")
    )
}

.lfs_write_class_plot_pdfs <- function(class_um_table, out_dir, unit_label = "uM") {
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  sample_cols <- setdiff(colnames(class_um_table), "Class")
  fnames <- make.unique(.lfs_sanitize_filename(class_um_table$Class), sep = "__dup")
  for (i in seq_len(nrow(class_um_table))) {
    long <- data.frame(sample = sample_cols,
                        value = suppressWarnings(as.numeric(class_um_table[i, sample_cols, drop = TRUE])),
                        stringsAsFactors = FALSE)
    p <- .lfs_class_scatter_plot(long, title = class_um_table$Class[i],
                                  y_label = sprintf("Concentration (%s)", unit_label))
    ggplot2::ggsave(file.path(out_dir, paste0(fnames[i], ".pdf")), p, width = 6, height = 4.5)
  }
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# intensity_plot/<Class>/<Lipid_Name>.pdf - 1 static, 3-panel PDF per feature
# (is / raw / final, stacked via patchwork), reproducing the real lipidflow
# vignette example exactly:
#   - "is"    - the matched Internal Standard's raw Peak_Area per sample
#               (KNOWN LIMITATION, kept per direct agreement: Y_IS_opt
#               currently holds only 1 QC-derived measurement per IS,
#               broadcast to every sample - so this panel renders FLAT until
#               Peak Extraction measures the IS per sample instead)
#   - "raw"   - this lipid's own raw Peak_Area per sample (from peak_table,
#               BEFORE the Area_lipid/Area_IS ratio)
#   - "final" - the fully-corrected concentration per sample (same numbers
#               already shown in the app's own interactive Feature Detail
#               chart)
# ---------------------------------------------------------------------------
.lfs_intensity_plot_page <- function(is_long, raw_long, final_long, lipid_name, final_unit_label) {
  p1 <- .lfs_class_scatter_plot(is_long, title = "Internal Standard (raw)", y_label = "Peak Area")
  p2 <- .lfs_class_scatter_plot(raw_long, title = "Lipid (raw)", y_label = "Peak Area")
  p3 <- .lfs_class_scatter_plot(final_long, title = "Final concentration", y_label = final_unit_label)
  patchwork::wrap_plots(p1, p2, p3, ncol = 1) + patchwork::plot_annotation(title = lipid_name)
}

.lfs_write_intensity_plot_pdfs <- function(bundle, out_dir, unit = c("um", "ug_ml")) {
  unit <- match.arg(unit)
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  final <- bundle$final
  raw <- bundle$raw_lipid
  unit_label <- if (unit == "um") "Concentration (uM)" else "Concentration (ug/mL)"

  id_cols <- c("peak_name", "variable_id", "Lipid_Name", "Class", "rt", ".side")
  sample_cols <- setdiff(colnames(raw), id_cols)

  # Precompute unique-per-Class filenames UP FRONT (not inside the loop) so 2
  # features that annotate to the identical Lipid_Name within the same Class
  # (a real possibility - isomers picked up as 2 separate variable_ids) get
  # "Name.pdf"/"Name__dup1.pdf" instead of the 2nd silently overwriting the
  # 1st - lipidflow's own real output assumes unique names per Class and
  # would have the same silent-overwrite risk, this just guards against it.
  fnames <- ave(.lfs_sanitize_filename(final$Lipid_Name), final$Class,
                FUN = function(x) make.unique(x, sep = "__dup"))

  for (i in seq_len(nrow(final))) {
    frow <- final[i, , drop = FALSE]
    rrow <- raw[raw$peak_name == frow$peak_name[1], , drop = FALSE]
    if (nrow(rrow) == 0) next

    side <- frow$.side[1]
    raw_is_table <- bundle$raw_is_by_side[[side]]
    match_item <- bundle$match_item_by_side[[side]]
    is_name <- .lfs_match_is_for_feature(frow$Class[1], frow$rt[1], match_item, raw_is_table)

    raw_long <- .lfs_pivot_long_from_row(rrow, sample_cols)
    final_unit_cols <- grep(paste0("_", unit, "$"), colnames(frow), value = TRUE)
    final_long <- data.frame(sample = sub(paste0("_", unit, "$"), "", final_unit_cols),
                              value = suppressWarnings(as.numeric(frow[1, final_unit_cols, drop = TRUE])),
                              stringsAsFactors = FALSE)

    if (!is.na(is_name) && !is.null(raw_is_table)) {
      is_row <- raw_is_table[raw_is_table$name == is_name, , drop = FALSE]
      is_sample_cols <- intersect(sample_cols, colnames(is_row))
      is_long <- .lfs_pivot_long_from_row(is_row, is_sample_cols)
    } else {
      is_long <- data.frame(sample = raw_long$sample, value = NA_real_)
    }

    p <- .lfs_intensity_plot_page(is_long, raw_long, final_long, frow$Lipid_Name[1], unit_label)
    class_dir <- file.path(out_dir, .lfs_sanitize_filename(frow$Class[1]))
    if (!dir.exists(class_dir)) dir.create(class_dir, recursive = TRUE)
    ggplot2::ggsave(file.path(class_dir, paste0(fnames[i], ".pdf")), p, width = 6, height = 9)
  }
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# plot_ug.pdf / plot_um.pdf - static save of the SAME composition ggplot
# .lfs_class_composition_plot() shows interactively (via
# .lfs_class_composition_ggplot(), pulled out specifically so this doesn't
# have to re-derive the chart).
# ---------------------------------------------------------------------------
.lfs_write_composition_pdf <- function(class_pct_table, out_file, unit_label = "") {
  p <- .lfs_class_composition_ggplot(class_pct_table, unit_label = unit_label)
  ggplot2::ggsave(out_file, p, width = 7, height = 5)
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# Top-level orchestrator called from mod_save_results.R: writes the FULL
# 10-item lipidflow-style export set into `out_dir` (created if needed) -
# IS_info_table.xlsx, lipid_data_{ug_ml,um,um_per}.xlsx,
# lipid_data_class_{ug_ml,um,um_per}.xlsx, plot_ug.pdf, plot_um.pdf,
# class_plot/, intensity_plot/ - all computed from the Combined (POS+NEG, or
# whichever single side is available) result, per direct agreement. `is_xlsx_path`
# is the raw uploaded Internal Standard file (copied through as-is, same
# behavior as the existing "Download Internal Standard table used" button).
# ---------------------------------------------------------------------------
.lfs_export_absolute_quantification_bundle <- function(full_pos, full_neg, is_xlsx_path, out_dir) {
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

  if (!is.null(is_xlsx_path) && file.exists(is_xlsx_path)) {
    file.copy(is_xlsx_path, file.path(out_dir, "IS_info_table.xlsx"), overwrite = TRUE)
  }

  bundle <- .lfs_build_quant_export_bundle(full_pos, full_neg)
  final_clean <- bundle$final
  final_clean$.side <- NULL

  by_unit <- .lfs_split_quant_table_by_unit(final_clean)
  class_summary <- .lfs_lipid_class_summary(final_clean)

  openxlsx::write.xlsx(by_unit$ug_ml, file.path(out_dir, "lipid_data_ug_ml.xlsx"), asTable = TRUE, overwrite = TRUE)
  openxlsx::write.xlsx(by_unit$um, file.path(out_dir, "lipid_data_um.xlsx"), asTable = TRUE, overwrite = TRUE)
  openxlsx::write.xlsx(class_summary$feature_pct_um, file.path(out_dir, "lipid_data_um_per.xlsx"), asTable = TRUE, overwrite = TRUE)
  openxlsx::write.xlsx(class_summary$class_ug_ml, file.path(out_dir, "lipid_data_class_ug_ml.xlsx"), asTable = TRUE, overwrite = TRUE)
  openxlsx::write.xlsx(class_summary$class_um, file.path(out_dir, "lipid_data_class_um.xlsx"), asTable = TRUE, overwrite = TRUE)
  openxlsx::write.xlsx(class_summary$class_pct_um, file.path(out_dir, "lipid_data_class_um_per.xlsx"), asTable = TRUE, overwrite = TRUE)

  .lfs_write_composition_pdf(class_summary$class_pct_ug_ml, file.path(out_dir, "plot_ug.pdf"), unit_label = "ug/mL")
  .lfs_write_composition_pdf(class_summary$class_pct_um, file.path(out_dir, "plot_um.pdf"), unit_label = "uM")

  .lfs_write_class_plot_pdfs(class_summary$class_um, file.path(out_dir, "class_plot"), unit_label = "uM")
  .lfs_write_intensity_plot_pdfs(bundle, file.path(out_dir, "intensity_plot"), unit = "um")

  invisible(out_dir)
}
