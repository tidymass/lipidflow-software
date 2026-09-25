# Helper functions for mod_small_tools.R - "Small Tools -> Peak Extraction".
#
# Giai doan 0 of the LipidFlow pipeline: extract QC peaks for each Internal
# Standard (IS) across candidate adduct forms, score each candidate with the
# Adduct Scoring Algorithm (0.6 x Peak Area + 0.4 x Peak Shape, see
# .lfs_score_candidates() below), and lock in a real (measured) RT +
# Peak_Area to normalize against later in Step 3 (Quantification). Output of
# this file's pipeline is "Y_IS_opt":
#   IS_ID, IS_Name, Selected_Adduct, Target_mz, Measured_RT, Peak_Area,
#   Norm_Area, Shape_Score, Combined_Score, Selection_Source
#
# Unlike the earlier version of this module (which read the raw QC file
# itself via MSnbase + xcms::chromatogram() and scored peak symmetry by
# hand), extraction now goes through the real `lipidflow::extract_targeted_peaks()`
# - the same function the reference multi-mode pipeline script uses for
# targeted extraction (Step 3/mod_quantification.R no longer calls it
# itself - see utils_quantification.R's file header: Step 3 now reads this
# module's own Y_IS_opt output directly instead of re-extracting from raw
# files), so Small Tools stops maintaining a second, parallel raw-file-
# reading code path.
# `lipidflow::extract_targeted_peaks()` only reports a peak's integrated area
# per sample column, not a shape/symmetry score - confirmed by reading
# lipidflow 0.0.1's own source (body(lipidflow::extract_targeted_peaks())),
# not guessed.
#
# Adduct Scoring Algorithm (replaces plain highest-Peak_Area ranking): the
# automatic "best adduct" pick is now a weighted combination of Peak Area
# (0.6) and Peak Shape (0.4). Peak Area comes from lipidflow as above; Peak
# Shape (a 0.0-1.0 Gaussian-fit R^2) is computed separately from the same
# raw-file EIC traces already extracted for the multi-adduct overlay chart
# (.lfs_extract_eic_traces(), MSnbase + xcms::chromatogram() - lipidflow
# itself never sees this). See .lfs_gaussian_fit_score()/.lfs_score_candidates()
# below for the full rationale (project's DAG case study: Hydrogen has the
# bigger peak area, Ammonium (NH4) has the cleaner shape - weighting shape
# higher stops the pick from always chasing the loudest signal). The
# analyst can still override any per-IS pick via red/blue/green toggle
# buttons in the UI (mod_small_tools.R's adduct_override_ui) - see
# .lfs_resolve_adduct_selection() for that logic. Everything here still runs
# fully automatically by default (no required manual review step), per the
# project's decision to keep the whole pipeline single-session/no human-in-
# the-loop unless the analyst chooses to intervene.
#
# Design note on testability: the real extraction (.lfs_run_peak_extraction_lipidflow())
# calls lipidflow::extract_targeted_peaks(), which needs a real raw mzXML/mzML
# file and isn't unit-testable without one. Every other function in this file
# (adduct math, target-table building, best-adduct selection, manual
# override) is pure and operates on plain data.frames, so it stays fully
# unit-testable with mock data - no MS packages involved.

# ---------------------------------------------------------------------------
# .lfs_csv_injection_safe() - APP-WIDE helper (not Small Tools-specific; it
# lives here because that's where the bug was first reported, but every
# downloadHandler()/write.csv() call in this app should route through it -
# see mod_peak_picking.R/mod_quantification.R/mod_small_tools.R/app_server.R,
# all updated to call this). Prefixes any character/factor cell that starts
# with =, +, -, @, tab, or CR with a single quote before writing to CSV.
#
# Real incident this fixes: a Y_IS_opt_POS.csv download opened in Excel
# showed "#NAME?" in the Selected_Adduct column (screenshot) - Excel
# auto-interprets a CSV cell starting with one of those characters as a
# FORMULA the instant the file is opened, regardless of CSV quoting (quoting
# only escapes commas/newlines for CSV PARSING; it does nothing for Excel's
# own separate post-parse formula-detection). "+H" (a genuinely common POS
# adduct value in this app) becomes the formula "=+H", which Excel tries to
# evaluate as a reference to an undefined name "H" -> #NAME?. Any NEG adduct
# ("-H", "-2H" etc.) hits the exact same problem via the leading "-".
#
# The leading single quote is Excel's own long-standing "force this cell to
# text" convention for CSV/text-file values - Excel strips the quote from
# what's displayed, it is not a stray character the person opening the file
# sees. This is also the standard mitigation recommended for CSV injection
# generally (OWASP), not something invented here.
#
# Applied to EVERY character/factor column of a data.frame, not just a
# hand-picked "adduct" column - any free-text field (an Internal Standard's
# own Name/ID from an uploaded CSV, a lipid class label, a compound name)
# could just as easily start with one of these characters and hit the same
# bug. Numeric/logical/Date columns are left untouched (never at risk, and
# coercing them to character would break their own CSV number formatting).
# Never mutates its input.
# ---------------------------------------------------------------------------
.lfs_csv_injection_safe <- function(df) {
  if (!is.data.frame(df) || nrow(df) == 0) return(df)
  risky_start <- c("=", "+", "-", "@", "\t", "\r")
  out <- df
  for (col in colnames(out)) {
    x <- out[[col]]
    if (is.character(x) || is.factor(x)) {
      x <- as.character(x)
      needs_prefix <- !is.na(x) & nzchar(x) & substr(x, 1, 1) %in% risky_start
      x[needs_prefix] <- paste0("'", x[needs_prefix])
      out[[col]] <- x
    }
  }
  out
}

# ---------------------------------------------------------------------------
# Reference adduct mass table. Delta masses are the standard monoisotopic
# adduct ion masses used across lipidomics MS software (MS-DIAL etc.):
# proton = 1.007276, Na+ = 22.989218, NH4+ = 18.033823, Cl- = 34.969402,
# HCOO- (formate) = 44.998201. m/z_calc = (Mass_IS + delta_mass) / |z|.
# ---------------------------------------------------------------------------
.lfs_is_adduct_table <- function(mode = c("positive", "negative")) {
  mode <- match.arg(mode)
  if (mode == "positive") {
    data.frame(
      adduct = c("+H", "+Na", "+NH4"),
      delta_mass = c(1.007276, 22.989218, 18.033823),
      z = c(1L, 1L, 1L),
      stringsAsFactors = FALSE
    )
  } else {
    data.frame(
      adduct = c("-H", "+Cl", "+HCOO"),
      delta_mass = c(-1.007276, 34.969402, 44.998201),
      z = c(1L, 1L, 1L),
      stringsAsFactors = FALSE
    )
  }
}

# ---------------------------------------------------------------------------
# Validate an Internal Standard table (already read into a data.frame) has
# the columns the rest of this pipeline needs: ID, Name, Formula,
# Accurate_Mass. Returns list(ok, message) rather than throwing, so callers
# (both Shiny UI and other utils_ functions) can decide how to react.
# ---------------------------------------------------------------------------
.lfs_validate_is_table_cols <- function(is_table) {
  required_cols <- c("ID", "Name", "Formula", "Accurate_Mass")

  if (is.null(is_table) || !is.data.frame(is_table)) {
    return(list(ok = FALSE, message = "Internal standard table must be a data.frame."))
  }
  if (nrow(is_table) == 0) {
    return(list(ok = FALSE, message = "Internal standard table is empty."))
  }
  missing_cols <- setdiff(required_cols, colnames(is_table))
  if (length(missing_cols) > 0) {
    return(list(ok = FALSE, message = paste0(
      "Missing required column(s): ", paste(missing_cols, collapse = ", "), "."
    )))
  }
  if (!is.numeric(is_table$Accurate_Mass)) {
    return(list(ok = FALSE, message = "Column 'Accurate_Mass' must be numeric."))
  }
  if (anyNA(is_table$Accurate_Mass) || any(is_table$Accurate_Mass <= 0)) {
    return(list(ok = FALSE, message = "Column 'Accurate_Mass' must contain positive, non-missing values."))
  }
  if (anyDuplicated(is_table$ID) > 0) {
    return(list(ok = FALSE, message = "Column 'ID' must contain unique values."))
  }
  list(ok = TRUE, message = NULL)
}

# ---------------------------------------------------------------------------
# Auto-fill blank/missing ID values in an uploaded IS table instead of
# letting them fall through to .lfs_validate_is_table_cols() and be rejected.
# Real user-supplied IS CSVs commonly leave the ID column blank (Name/
# Formula/Accurate_Mass are the columns people actually fill in by hand) -
# erroring out on that is pure friction, since a sequential placeholder ID
# is all this pipeline actually needs (it's only used to key IS rows through
# to Y_IS_opt, never shown to instrument software). Handles both a
# completely-missing ID column and NA/""/whitespace-only individual values;
# generated IDs (IS_001, IS_002, ...) skip over any value that collides with
# an ID a user DID supply, so a table that already has "IS_002" filled in
# for one row and blanks elsewhere still ends up with all-unique IDs.
# Never mutates its input - operates on a local copy, returns a new
# data.frame.
# ---------------------------------------------------------------------------
.lfs_autofill_is_ids <- function(is_table) {
  if (is.null(is_table) || !is.data.frame(is_table)) return(is_table)

  out <- is_table
  if (!"ID" %in% colnames(out)) out$ID <- NA_character_

  ids <- as.character(out$ID)
  is_blank <- is.na(ids) | !nzchar(trimws(ids))
  if (!any(is_blank)) return(out)

  existing <- ids[!is_blank]
  generated <- character(0)
  next_n <- 1L
  while (length(generated) < sum(is_blank)) {
    candidate <- sprintf("IS_%03d", next_n)
    next_n <- next_n + 1L
    if (!(candidate %in% existing) && !(candidate %in% generated)) {
      generated <- c(generated, candidate)
    }
  }
  ids[is_blank] <- generated
  out$ID <- ids
  out
}

# ---------------------------------------------------------------------------
# Read + validate the uploaded IS CSV in one step (used by mod_small_tools.R).
# Blank/missing ID values are auto-filled (see .lfs_autofill_is_ids()) before
# validation, so a table with an empty ID column is accepted rather than
# rejected with a "must contain unique values" error.
# ---------------------------------------------------------------------------
.lfs_read_is_csv <- function(filepath) {
  if (is.null(filepath) || !nzchar(filepath) || !file.exists(filepath)) {
    return(list(ok = FALSE, data = NULL, message = paste0("File not found: ", filepath)))
  }
  is_table <- tryCatch(
    utils::read.csv(filepath, stringsAsFactors = FALSE, check.names = FALSE),
    error = function(e) {
      message("[utils_small_tools] Failed to read IS CSV: ", conditionMessage(e))
      NULL
    }
  )
  if (is.null(is_table)) {
    return(list(ok = FALSE, data = NULL, message = "Could not parse the uploaded file as CSV."))
  }
  is_table <- .lfs_autofill_is_ids(is_table)
  check <- .lfs_validate_is_table_cols(is_table)
  if (!isTRUE(check$ok)) return(list(ok = FALSE, data = NULL, message = check$message))
  list(ok = TRUE, data = is_table, message = NULL)
}

# ---------------------------------------------------------------------------
# Vectorized theoretical m/z calculation: cross-join every IS row against
# every requested adduct (base R's merge(by = character(0)) is the standard
# idiom for a Cartesian product), then m/z_calc = (Mass_IS + delta)/|z|.
# Does NOT mutate is_table - merge() always returns a new object.
# ---------------------------------------------------------------------------
.lfs_calc_target_mz <- function(is_table, adducts, mode = c("positive", "negative")) {
  mode <- match.arg(mode)

  check <- .lfs_validate_is_table_cols(is_table)
  if (!isTRUE(check$ok)) stop(".lfs_calc_target_mz: ", check$message)

  if (is.null(adducts) || length(adducts) == 0 || !is.character(adducts)) {
    stop(".lfs_calc_target_mz: 'adducts' must be a non-empty character vector.")
  }

  adduct_ref <- .lfs_is_adduct_table(mode)
  unknown <- setdiff(adducts, adduct_ref$adduct)
  if (length(unknown) > 0) {
    stop(".lfs_calc_target_mz: unsupported adduct(s) for ", mode, " mode: ",
         paste(unknown, collapse = ", "))
  }
  adduct_sel <- adduct_ref[adduct_ref$adduct %in% adducts, , drop = FALSE]

  is_small <- is_table[, c("ID", "Name", "Accurate_Mass"), drop = FALSE]
  combo <- merge(is_small, adduct_sel, by = character(0))
  combo$Target_mz <- (combo$Accurate_Mass + combo$delta_mass) / abs(combo$z)

  data.frame(
    IS_ID = combo$ID,
    IS_Name = combo$Name,
    Adduct = combo$adduct,
    z = combo$z,
    Target_mz = combo$Target_mz,
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# Build the (name, mz, rt, adduct) target table lipidflow::extract_targeted_peaks()
# needs, on top of .lfs_calc_target_mz(). Column order matters here, not just
# names: extract_targeted_peaks()'s own internal extractPeaks2() reads mz via
# positional dplyr::pull(2) and (when present) rt via dplyr::pull(3) - so mz
# and rt MUST be the 2nd/3rd columns of the xlsx this table gets written to,
# not just present somewhere - confirmed by reading lipidflow's source, not
# guessed. `name` is built as "<IS_ID>__<Adduct>" so every row is unique even
# when a single IS is scanned across several candidate adducts (IS_ID alone
# would collide). `rt` is a fixed placeholder (100), not the IS's true
# retention time - the true RT isn't known ahead of a QC scan - paired with a
# wide rt.tolerance at the call site (see .lfs_run_peak_extraction_lipidflow()),
# the same "rt <- 100 + huge rt.tolerance" convention already used by
# .lfs_make_is_targets() (utils_annotation.R) and utils_S.R's is_targets.
# IS_ID/IS_Name are carried along as extra columns purely for this app's own
# bookkeeping (grouping candidate adducts back to one IS after extraction) -
# lipidflow ignores columns it doesn't need. Never mutates its input.
# ---------------------------------------------------------------------------
.lfs_build_is_adduct_target_table <- function(is_table, adducts, mode = c("positive", "negative")) {
  mode <- match.arg(mode)
  base <- .lfs_calc_target_mz(is_table, adducts, mode)
  data.frame(
    name = paste(base$IS_ID, base$Adduct, sep = "__"),
    mz = base$Target_mz,
    rt = 100,
    adduct = base$Adduct,
    IS_ID = base$IS_ID,
    IS_Name = base$IS_Name,
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# Join lipidflow::extract_targeted_peaks()'s raw quantification_table (name,
# mz, rt, adduct, <one column per raw sample file - integrated peak area>)
# back onto the target table's IS_ID/IS_Name bookkeeping columns, and collapse
# the sample columns into one Peak_Area per row (mean across sample columns,
# NA-safe - a QC run normally contributes exactly one sample column, but this
# stays correct if more than one QC replicate was included). Shared by
# .lfs_select_best_adduct_from_quant() and .lfs_apply_manual_adduct_from_quant()
# so both read from exactly one place. Never mutates either input.
# ---------------------------------------------------------------------------
.lfs_quant_with_peak_area <- function(quant_table, target_table) {
  if (!is.data.frame(quant_table)) stop(".lfs_quant_with_peak_area: 'quant_table' must be a data.frame.")
  if (!is.data.frame(target_table)) stop(".lfs_quant_with_peak_area: 'target_table' must be a data.frame.")

  required_quant <- c("name", "mz", "rt", "adduct")
  missing_q <- setdiff(required_quant, colnames(quant_table))
  if (length(missing_q) > 0) {
    stop(".lfs_quant_with_peak_area: 'quant_table' is missing column(s): ", paste(missing_q, collapse = ", "))
  }
  required_target <- c("name", "IS_ID", "IS_Name")
  missing_t <- setdiff(required_target, colnames(target_table))
  if (length(missing_t) > 0) {
    stop(".lfs_quant_with_peak_area: 'target_table' is missing column(s): ", paste(missing_t, collapse = ", "))
  }

  if (nrow(quant_table) == 0) {
    return(data.frame(name = character(), mz = numeric(), rt = numeric(), adduct = character(),
                       IS_ID = character(), IS_Name = character(), Peak_Area = numeric(),
                       stringsAsFactors = FALSE))
  }

  sample_cols <- setdiff(colnames(quant_table), c("name", "mz", "rt", "adduct"))
  if (length(sample_cols) == 0) {
    stop(".lfs_quant_with_peak_area: 'quant_table' has no sample (peak-area) columns.")
  }

  peak_area <- vapply(seq_len(nrow(quant_table)), function(i) {
    vals <- suppressWarnings(as.numeric(quant_table[i, sample_cols]))
    if (all(is.na(vals))) return(NA_real_)
    mean(vals, na.rm = TRUE)
  }, numeric(1))

  x <- quant_table[, c("name", "mz", "rt", "adduct"), drop = FALSE]
  x$Peak_Area <- peak_area
  merge(x, target_table[, c("name", "IS_ID", "IS_Name"), drop = FALSE], by = "name", all.x = TRUE, sort = FALSE)
}

# ---------------------------------------------------------------------------
# Fit a single-Gaussian curve to one EIC trace (rt, intensity) and return the
# fit's R^2 as a 0.0-1.0 "Peak Shape" score - half of the Adduct Scoring
# Algorithm (see .lfs_score_candidates() below). Needs >= 5 distinct, finite
# (rt, intensity) points with some intensity variation to even attempt a fit;
# anything thinner than that, or an nls() call that errors/fails to converge,
# returns NA so a genuinely unscoreable trace (empty EIC window, flat noise)
# degrades to "no shape signal" rather than crashing the scoring pass. R^2 is
# clamped to [0, 1] - a bad Gaussian fit can score WORSE than the trace's own
# mean (negative R^2), and that should read as "zero shape quality", not a
# negative number feeding into a weighted sum. Pure/vectorizable-per-row, no
# side effects.
# ---------------------------------------------------------------------------
.lfs_gaussian_fit_score <- function(rt, intensity) {
  rt <- suppressWarnings(as.numeric(rt))
  intensity <- suppressWarnings(as.numeric(intensity))
  ok <- !is.na(rt) & !is.na(intensity)
  rt <- rt[ok]; intensity <- intensity[ok]
  if (length(rt) < 5 || length(unique(rt)) < 5) return(NA_real_)

  intensity[intensity < 0] <- 0
  if (all(intensity == 0) || stats::sd(intensity) == 0) return(NA_real_)

  A0 <- max(intensity)
  mu0 <- rt[which.max(intensity)]
  sigma0 <- stats::sd(rt)
  if (!is.finite(sigma0) || sigma0 <= 0) sigma0 <- diff(range(rt)) / 4
  if (!is.finite(sigma0) || sigma0 <= 0) return(NA_real_)

  # warnOnly = TRUE means a non-converged fit returns a best-effort result
  # PLUS a warning, rather than erroring - deliberately only catching error=
  # here (via suppressWarnings(), not a warning= handler) so that routine
  # "didn't fully converge" warnings don't discard an otherwise-usable fit;
  # only a genuine error (singular gradient, non-finite start values, etc.)
  # should turn into NA.
  fit <- tryCatch(
    suppressWarnings(stats::nls(
      intensity ~ A * exp(-((rt - mu)^2) / (2 * sigma^2)),
      start = list(A = A0, mu = mu0, sigma = sigma0),
      control = stats::nls.control(maxiter = 100, warnOnly = TRUE)
    )),
    error = function(e) NULL
  )
  if (is.null(fit)) return(NA_real_)

  predicted <- tryCatch(stats::fitted(fit), error = function(e) NULL)
  if (is.null(predicted) || length(predicted) != length(intensity)) return(NA_real_)

  ss_res <- sum((intensity - predicted)^2)
  ss_tot <- sum((intensity - mean(intensity))^2)
  if (!is.finite(ss_tot) || ss_tot <= 0) return(NA_real_)

  r_squared <- 1 - (ss_res / ss_tot)
  if (!is.finite(r_squared)) return(NA_real_)
  max(0, min(1, r_squared))
}

# ---------------------------------------------------------------------------
# One Peak Shape score (.lfs_gaussian_fit_score()) per (IS_ID, adduct)
# candidate, from the SAME rt/intensity EIC traces already extracted for the
# multi-adduct overlay chart (.lfs_extract_eic_traces()/.lfs_unnest_eic() use
# the unnested long form; this reads the wide, one-row-per-candidate form
# .lfs_extract_eic_traces() itself returns). Returns
# data.frame(IS_ID, adduct, Shape_Score) - NA where a trace couldn't be
# scored. eic_data may be NULL/zero-row (that side's EIC pass failed or
# wasn't run) - returns a zero-row table rather than erroring, so callers
# degrade to area-only ranking (see .lfs_score_candidates()). Never mutates
# its input.
# ---------------------------------------------------------------------------
.lfs_shape_scores_from_eic <- function(eic_data) {
  empty_out <- data.frame(IS_ID = character(), adduct = character(), Shape_Score = numeric(),
                           stringsAsFactors = FALSE)
  if (is.null(eic_data) || !is.data.frame(eic_data) || nrow(eic_data) == 0) return(empty_out)

  required <- c("IS_ID", "adduct", "rt", "intensity")
  missing <- setdiff(required, colnames(eic_data))
  if (length(missing) > 0) {
    stop(".lfs_shape_scores_from_eic: 'eic_data' is missing column(s): ", paste(missing, collapse = ", "))
  }

  scores <- vapply(seq_len(nrow(eic_data)), function(i) {
    .lfs_gaussian_fit_score(eic_data$rt[[i]], eic_data$intensity[[i]])
  }, numeric(1))
  data.frame(IS_ID = eic_data$IS_ID, adduct = eic_data$adduct, Shape_Score = scores,
             stringsAsFactors = FALSE)
}

# ---------------------------------------------------------------------------
# THE Adduct Scoring Algorithm (replaces plain highest-Peak_Area ranking):
# for every IS, Peak_Area is normalized against that IS's OWN max candidate
# (base = 1.0), putting it on the same 0.0-1.0 scale as Shape_Score, then
# combined as weight_shape*Shape_Score + weight_area*Norm_Area (defaults
# 0.4/0.6, per direct agreement - originally 0.6 shape/0.4 area from the
# project's DAG case study, where the Hydrogen adduct had the larger peak
# area but Ammonium (NH4) had the cleaner/more Gaussian peak, then swapped to
# weight Peak Area higher instead). A candidate with no usable Shape_Score (NA -
# empty/too-short EIC trace, see .lfs_gaussian_fit_score()) ranks on
# Norm_Area alone for that one row rather than being treated as
# Shape_Score = 0, which would unfairly bury an otherwise-real peak just
# because its trace couldn't be fit. When eic_data is NULL/has no matching
# rows at all (the EIC pass wasn't run or failed entirely for this side),
# every row falls back this way, so ranking degrades gracefully to
# Norm_Area-only - numerically equivalent to the old pure-Peak_Area ranking,
# since dividing every candidate by the same per-IS max doesn't change their
# relative order. Never mutates its inputs.
# ---------------------------------------------------------------------------
.lfs_score_candidates <- function(quant_table, target_table, eic_data = NULL,
                                   weight_shape = 0.4, weight_area = 0.6) {
  empty_out <- data.frame(
    IS_ID = character(), IS_Name = character(), adduct = character(),
    mz = numeric(), rt = numeric(), Peak_Area = numeric(),
    Norm_Area = numeric(), Shape_Score = numeric(), Combined_Score = numeric(),
    stringsAsFactors = FALSE
  )
  merged <- .lfs_quant_with_peak_area(quant_table, target_table)
  if (nrow(merged) == 0) return(empty_out)

  area <- ifelse(is.na(merged$Peak_Area), 0, merged$Peak_Area)
  max_area_by_is <- stats::ave(area, merged$IS_ID, FUN = function(x) {
    m <- suppressWarnings(max(x, na.rm = TRUE))
    if (!is.finite(m) || m <= 0) 1 else m
  })
  merged$Norm_Area <- area / max_area_by_is

  shape <- .lfs_shape_scores_from_eic(eic_data)
  merged$Shape_Score <- NA_real_
  if (nrow(shape) > 0) {
    key <- paste(merged$IS_ID, merged$adduct, sep = "\r")
    shape_key <- paste(shape$IS_ID, shape$adduct, sep = "\r")
    merged$Shape_Score <- shape$Shape_Score[match(key, shape_key)]
  }

  has_shape <- !is.na(merged$Shape_Score)
  merged$Combined_Score <- merged$Norm_Area
  merged$Combined_Score[has_shape] <- weight_shape * merged$Shape_Score[has_shape] +
    weight_area * merged$Norm_Area[has_shape]

  merged[, c("IS_ID", "IS_Name", "adduct", "mz", "rt", "Peak_Area",
             "Norm_Area", "Shape_Score", "Combined_Score"), drop = FALSE]
}

# ---------------------------------------------------------------------------
# Pick the best adduct per IS by highest Combined_Score (see
# .lfs_score_candidates() above). Rows with unusable (NA/-Inf) scores are
# ranked last, never chosen unless literally every candidate for that IS is
# unusable. eic_data = NULL (default) makes this behave exactly like the old
# pure-Peak_Area ranking - see .lfs_score_candidates()'s header. Output shape
# matches the pre-scoring version (IS_ID, IS_Name, Selected_Adduct,
# Target_mz, Measured_RT, Peak_Area) with Norm_Area/Shape_Score/Combined_Score
# appended, so .lfs_combine_y_is_opt() and the CSV download need no changes,
# while the new columns make the automatic pick auditable in the UI/export.
# ---------------------------------------------------------------------------
.lfs_select_best_adduct_from_quant <- function(quant_table, target_table, eic_data = NULL,
                                                weight_shape = 0.4, weight_area = 0.6) {
  empty_out <- data.frame(
    IS_ID = character(), IS_Name = character(), Selected_Adduct = character(),
    Target_mz = numeric(), Measured_RT = numeric(), Peak_Area = numeric(),
    Norm_Area = numeric(), Shape_Score = numeric(), Combined_Score = numeric(),
    stringsAsFactors = FALSE
  )
  scored <- .lfs_score_candidates(quant_table, target_table, eic_data, weight_shape, weight_area)
  if (nrow(scored) == 0) return(empty_out)

  scored$rank_score <- ifelse(is.na(scored$Combined_Score), -Inf, scored$Combined_Score)
  scored <- scored[order(scored$IS_ID, -scored$rank_score), , drop = FALSE]
  best <- scored[!duplicated(scored$IS_ID), , drop = FALSE]
  best <- best[order(best$IS_ID), , drop = FALSE]

  data.frame(
    IS_ID = best$IS_ID,
    IS_Name = best$IS_Name,
    Selected_Adduct = best$adduct,
    Target_mz = best$mz,
    Measured_RT = best$rt,
    Peak_Area = best$Peak_Area,
    Norm_Area = round(best$Norm_Area, 4),
    Shape_Score = round(best$Shape_Score, 4),
    Combined_Score = round(best$Combined_Score, 4),
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# Resolve one adduct per IS from .lfs_score_candidates()'s scored candidates,
# applying the user's manual overrides on top of the automatic
# (highest-Combined_Score) pick - the logic behind mod_small_tools.R's
# red/blue/green toggle buttons (one button per candidate adduct, per IS):
#   - "excluded" (red)  - dropped from consideration for that IS.
#   - "selected" (green) - wins outright over every other candidate for that
#     IS, scored or not (the analyst's own visual judgement of the EIC chart
#     overrides the algorithm).
#   - anything not listed in `overrides` - "auto" (blue) - ranked normally.
# If a user excludes every single candidate for one IS, that IS's exclusions
# are ignored entirely and it falls back to the automatic pick among ALL its
# candidates - there must always be SOME best-available adduct reported, even
# if every one of them looks poor. `overrides` is a data.frame with columns
# IS_ID, adduct, state (state in c("excluded", "selected")); NULL/zero-row
# means no manual overrides at all (pure automatic pick, same result as
# .lfs_select_best_adduct_from_quant()). Never mutates its inputs.
# ---------------------------------------------------------------------------
.lfs_resolve_adduct_selection <- function(scored, overrides = NULL) {
  empty_out <- data.frame(
    IS_ID = character(), IS_Name = character(), Selected_Adduct = character(),
    Target_mz = numeric(), Measured_RT = numeric(), Peak_Area = numeric(),
    Norm_Area = numeric(), Shape_Score = numeric(), Combined_Score = numeric(),
    Selection_Source = character(), stringsAsFactors = FALSE
  )
  if (is.null(scored) || !is.data.frame(scored) || nrow(scored) == 0) return(empty_out)

  scored$rank_score <- ifelse(is.na(scored$Combined_Score), -Inf, scored$Combined_Score)
  scored$.key <- paste(scored$IS_ID, scored$adduct, sep = "\r")

  excluded_key <- character(0)
  selected_key <- character(0)
  if (is.data.frame(overrides) && nrow(overrides) > 0) {
    key <- paste(overrides$IS_ID, overrides$adduct, sep = "\r")
    excluded_key <- key[overrides$state == "excluded"]
    selected_key <- key[overrides$state == "selected"]
  }

  pick_for_is <- function(rows) {
    forced <- rows[rows$.key %in% selected_key, , drop = FALSE]
    if (nrow(forced) > 0) {
      best <- forced[order(-forced$rank_score), , drop = FALSE][1, , drop = FALSE]
      best$Selection_Source <- "manual"
      return(best)
    }
    available <- rows[!(rows$.key %in% excluded_key), , drop = FALSE]
    if (nrow(available) == 0) available <- rows # every candidate excluded - fall back to all
    best <- available[order(-available$rank_score), , drop = FALSE][1, , drop = FALSE]
    best$Selection_Source <- "auto"
    best
  }

  best_rows <- do.call(rbind, lapply(split(scored, scored$IS_ID), pick_for_is))
  best_rows <- best_rows[order(best_rows$IS_ID), , drop = FALSE]

  data.frame(
    IS_ID = best_rows$IS_ID,
    IS_Name = best_rows$IS_Name,
    Selected_Adduct = best_rows$adduct,
    Target_mz = best_rows$mz,
    Measured_RT = best_rows$rt,
    Peak_Area = best_rows$Peak_Area,
    Norm_Area = round(best_rows$Norm_Area, 4),
    Shape_Score = round(best_rows$Shape_Score, 4),
    Combined_Score = round(best_rows$Combined_Score, 4),
    Selection_Source = best_rows$Selection_Source,
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# Combine POS-sourced and NEG-sourced Y_IS_opt tables (mod_small_tools.R runs
# both ion modes from one click) into the single table
# pipeline_state$small_tools_is_opt expects. This module is standalone (own
# top-level nav item, not part of the lipidAnalysis step flow) - Step 3
# (Quantification) no longer consumes small_tools_is_opt, see
# utils_quantification.R. An IS measured in both modes is resolved here by
# keeping only the higher-Peak_Area row per IS_Name before the two tables
# are combined. Either argument may be NULL or zero-row (that side wasn't
# run, or produced no result); returns a zero-row table with the right
# columns if both are. Never mutates its inputs - rbind()/subsetting always
# copy.
# ---------------------------------------------------------------------------
.lfs_combine_y_is_opt <- function(pos = NULL, neg = NULL) {
  empty_out <- data.frame(
    IS_ID = character(), IS_Name = character(), Selected_Adduct = character(),
    Target_mz = numeric(), Measured_RT = numeric(), Peak_Area = numeric(),
    stringsAsFactors = FALSE
  )
  parts <- Filter(function(x) is.data.frame(x) && nrow(x) > 0, list(pos, neg))
  if (length(parts) == 0) return(empty_out)

  combined <- do.call(rbind, parts)
  missing_cols <- setdiff(c("IS_Name", "Peak_Area"), colnames(combined))
  if (length(missing_cols) > 0) {
    stop(".lfs_combine_y_is_opt: input(s) missing required column(s): ",
         paste(missing_cols, collapse = ", "))
  }

  combined <- combined[order(combined$IS_Name, -combined$Peak_Area), , drop = FALSE]
  combined <- combined[!duplicated(combined$IS_Name), , drop = FALSE]
  combined <- combined[order(combined$IS_Name), , drop = FALSE]
  rownames(combined) <- NULL
  combined
}

# ---------------------------------------------------------------------------
# Raw-file EIC traces, for VISUAL inspection only - not the source of
# Peak_Area/Measured_RT in Y_IS_opt (that's lipidflow::extract_targeted_peaks(),
# see .lfs_run_peak_extraction_lipidflow() below). The point of this second,
# independent extraction is the request to show every candidate adduct for an
# Internal Standard overlaid on ONE chart (one color per adduct) so the
# analyst can visually judge peak shape + intensity across adducts side by
# side - lipidflow's own output only gives back an integrated Peak_Area
# number per feature plus a SEPARATE self-contained HTML widget per feature
# (see .lfs_run_peak_extraction_lipidflow()'s eic_dir), neither of which is a
# combined, color-coded overlay. Real backend: MSnbase::readMSData() +
# xcms::chromatogram() directly on the same QC raw file and target table
# already used for the lipidflow call, so the traces plotted are guaranteed
# to correspond exactly to the same targets lipidflow scored (same mz/adduct
# per row) - not a second, independently-computed target list that could
# drift out of sync.
#
# Design note on testability: raw-file EIC extraction (xcms::chromatogram()
# on an MSnbase raw object) cannot be meaningfully unit-tested without a real
# vendor raw file, so .lfs_extract_eic_traces() takes the chromatogram
# extraction and result-unpacking as injectable functions (chromatogram_fn,
# unpack_fn) - defaulting to the real xcms/MSnbase calls in production, but
# swappable for a synthetic stub in tests.
# ---------------------------------------------------------------------------
.lfs_read_raw_ms_file <- function(path) {
  if (is.null(path) || !nzchar(path) || !file.exists(path)) {
    stop(".lfs_read_raw_ms_file: file not found: ", path)
  }
  ext <- tolower(tools::file_ext(path))
  if (!ext %in% c("mzxml", "mzml")) {
    stop(".lfs_read_raw_ms_file: unsupported file extension '.", ext,
         "' - expected .mzXML or .mzML.")
  }
  tryCatch({
    message("[utils_small_tools] Reading raw MS file for EIC display: ", path)
    MSnbase::readMSData(path, mode = "onDisk", msLevel. = 1)
  }, error = function(e) {
    stop(".lfs_read_raw_ms_file: failed to read '", path, "': ", conditionMessage(e))
  })
}

# ---------------------------------------------------------------------------
# Extract an EIC per target_table row (one row per IS x adduct combo, as
# built by .lfs_build_is_adduct_target_table()) from an already-loaded raw
# object. Adds rt/intensity list-columns to target_table; never mutates its
# input.
#
# ONE vectorized xcms::chromatogram() call across every row, not one call per
# row - lipidflow's own extractPeaks2() (the function's real upstream, see
# lipidflow 0.0.1's utilities.R) already does this by building a single
# n-row mz matrix; this function used to loop chromatogram_fn() once per row
# instead, and that turned out to be the actual cause of a real ~25-minute
# Extract Peaks run for one QC file (20 Internal Standards x 3 POS adducts =
# 60 rows). Benchmarked on a real 45MB/2588-scan QC .mzXML file: 60 separate
# chromatogram() calls took 1498s (~25 min); one batched call over the same
# 60 mz windows took 73s - a confirmed 20.4x speedup, byte-identical results.
# Each xcms::chromatogram() call on an on-disk MSnExp object re-scans/filters
# the file's whole spectra index regardless of how narrow the mz window is,
# so looping pays that fixed per-call cost 60 times instead of once.
#
# A single mz range still fails independently of the rest where possible: a
# genuinely empty EIC window for one IS x adduct combo is a normal, expected
# result, not a bug. Since the raw scan itself is now ONE call, that call
# either returns a result for every row or throws for the whole batch - a
# batch-level failure degrades every row to an empty trace together (caught
# below), same graceful-degradation behavior the caller
# (.lfs_run_peak_extraction_lipidflow()) already applies one level up when
# the whole EIC pass fails. unpack_fn() below still runs, and is still
# tryCatch()'d, per row - a single malformed Chromatogram object among an
# otherwise-successful batch still degrades to an empty trace for just that
# row, not the whole batch.
# ---------------------------------------------------------------------------
.lfs_extract_eic_traces <- function(raw_object, target_table, ppm = 15, rt_window = NULL,
                                     chromatogram_fn = NULL, unpack_fn = NULL) {
  if (is.null(raw_object)) stop(".lfs_extract_eic_traces: 'raw_object' must not be NULL.")
  if (!is.data.frame(target_table)) stop(".lfs_extract_eic_traces: 'target_table' must be a data.frame.")
  required <- c("IS_ID", "IS_Name", "adduct", "mz")
  missing <- setdiff(required, colnames(target_table))
  if (length(missing) > 0) {
    stop(".lfs_extract_eic_traces: 'target_table' is missing column(s): ", paste(missing, collapse = ", "))
  }
  if (!is.numeric(ppm) || length(ppm) != 1 || is.na(ppm) || ppm <= 0) {
    stop(".lfs_extract_eic_traces: 'ppm' must be a single positive number.")
  }

  # chromatogram_fn is now called ONCE for the whole batch - takes the full
  # n-row mz matrix + one shared rt range, returns a LIST of n raw
  # chromatogram objects (one per target_table row, same order). Confirmed
  # against a real xcms::chromatogram() call (see this function's header
  # benchmark) that a single length-2 `rt` vector is correctly recycled
  # across every row of an n-row `mz` matrix - no need to build an n-row rt
  # matrix ourselves when every row shares the same window (rt_window is
  # always a single global range in every current caller, never per-row).
  if (is.null(chromatogram_fn)) {
    chromatogram_fn <- function(object, mz, rt) {
      res <- xcms::chromatogram(object, mz = mz, rt = rt, aggregationFun = "sum")
      lapply(seq_len(nrow(mz)), function(i) res[[i, 1]])
    }
  }
  if (is.null(unpack_fn)) {
    unpack_fn <- function(ch) {
      list(rt = as.numeric(MSnbase::rtime(ch)), intensity = as.numeric(MSnbase::intensity(ch)))
    }
  }

  rt_rng <- if (is.null(rt_window)) c(0, Inf) else rt_window
  delta <- target_table$mz * ppm / 1e6
  mz_range <- cbind(target_table$mz - delta, target_table$mz + delta)
  n <- nrow(target_table)

  chrom_list <- tryCatch(chromatogram_fn(raw_object, mz_range, rt_rng), error = function(e) {
    message("[utils_small_tools] EIC batch extraction failed for all ", n, " target(s): ",
            conditionMessage(e))
    NULL
  })

  empty_trace <- list(rt = numeric(0), intensity = numeric(0))
  traces <- if (is.null(chrom_list)) {
    replicate(n, empty_trace, simplify = FALSE)
  } else {
    lapply(chrom_list, function(ch) {
      tryCatch(unpack_fn(ch), error = function(e) {
        message("[utils_small_tools] EIC trace unpack failed for one target: ", conditionMessage(e))
        empty_trace
      })
    })
  }

  out <- target_table
  out$rt <- lapply(traces, function(tr) tr$rt)
  out$intensity <- lapply(traces, function(tr) tr$intensity)
  out
}

# ---------------------------------------------------------------------------
# Unnest a target_table-with-traces (rt/intensity list-columns, see
# .lfs_extract_eic_traces()) into one row per (IS, adduct, point) for
# plotting - one line per adduct, one color per adduct, one facet per IS.
# Pure and testable; rows whose rt/intensity vectors are empty simply
# contribute no rows to the output.
# ---------------------------------------------------------------------------
.lfs_unnest_eic <- function(eic_data) {
  required_cols <- c("IS_ID", "IS_Name", "adduct", "rt", "intensity")
  if (is.null(eic_data) || !is.data.frame(eic_data)) {
    stop(".lfs_unnest_eic: 'eic_data' must be a data.frame.")
  }
  missing_cols <- setdiff(required_cols, colnames(eic_data))
  if (length(missing_cols) > 0) {
    stop(".lfs_unnest_eic: missing required column(s): ", paste(missing_cols, collapse = ", "))
  }
  if (nrow(eic_data) == 0) {
    return(data.frame(IS_ID = character(), IS_Name = character(), Adduct = character(),
                       rt = numeric(), intensity = numeric(), stringsAsFactors = FALSE))
  }

  rows <- purrr::pmap(
    list(IS_ID = eic_data$IS_ID, IS_Name = eic_data$IS_Name, Adduct = eic_data$adduct,
         rt = eic_data$rt, intensity = eic_data$intensity),
    function(IS_ID, IS_Name, Adduct, rt, intensity) {
      n <- length(rt)
      if (n == 0) return(NULL)
      data.frame(IS_ID = rep(IS_ID, n), IS_Name = rep(IS_Name, n), Adduct = rep(Adduct, n),
                 rt = rt, intensity = intensity, stringsAsFactors = FALSE)
    }
  )
  dplyr::bind_rows(rows)
}

# ---------------------------------------------------------------------------
# Top-level orchestration used by mod_small_tools.R: stage the QC raw file +
# target table into a throwaway working folder in the exact layout
# lipidflow::extract_targeted_peaks() expects (raw file(s) anywhere under
# `path`, target xlsx directly at `path`), run the real extraction, then pick
# the best adduct per IS. Every failure mode (bad file, bad params,
# extraction error) is caught here and turned into a structured result
# instead of an uncaught error reaching the Shiny session, per the "no
# uncaught exceptions in backend code" requirement.
#
# forced_targeted_peak_table_name is explicitly passed as NULL - lipidflow's
# own default ("forced_table.xlsx") makes extract_targeted_peaks() try to
# read that file from the (empty, freshly-created) output folder BEFORE it
# ever writes anything there, which errors "file not found" on any fresh run
# - confirmed by reading lipidflow 0.0.1's source, not guessed. NULL is the
# function's own documented escape hatch (its own `if (!is.null(...))` guard
# skips that read entirely).
# ---------------------------------------------------------------------------
.lfs_run_peak_extraction_lipidflow <- function(qc_file_path, is_table, adducts,
                                                mode = c("positive", "negative"),
                                                ppm = 15, rt_tolerance = 1e5,
                                                threads = 1, work_dir = NULL) {
  mode <- match.arg(mode)
  tryCatch({
    if (is.null(qc_file_path) || !nzchar(qc_file_path) || !file.exists(qc_file_path)) {
      stop("QC raw file not found: ", qc_file_path)
    }
    ext <- tolower(tools::file_ext(qc_file_path))
    if (!ext %in% c("mzxml", "mzml")) {
      stop("unsupported file extension '.", ext, "' - expected .mzXML or .mzML.")
    }

    if (is.null(work_dir)) work_dir <- tempfile("lfs_peak_extraction_")
    mode_dir <- file.path(work_dir, mode)
    qc_dir <- file.path(mode_dir, "QC")
    dir.create(qc_dir, recursive = TRUE, showWarnings = FALSE)
    qc_dest <- file.path(qc_dir, basename(qc_file_path))
    file.copy(qc_file_path, qc_dest, overwrite = TRUE)

    target_table <- .lfs_build_is_adduct_target_table(is_table, adducts, mode)
    target_file <- "is_adduct_targets.xlsx"
    openxlsx::write.xlsx(
      target_table[, c("name", "mz", "rt", "adduct", "IS_ID", "IS_Name")],
      file.path(mode_dir, target_file), asTable = TRUE, overwrite = TRUE
    )

    cat("[peak extraction] running lipidflow::extract_targeted_peaks() for ", mode, "...\n", sep = "")
    flush(stdout())
    lipidflow::extract_targeted_peaks(
      path = mode_dir, output_path_name = "IS_Extraction",
      targeted_targeted_peak_table_name = target_file,
      forced_targeted_peak_table_name = NULL,
      from_lipid_search = FALSE, fit.gaussian = TRUE, integrate_xcms = TRUE,
      output_eic = TRUE, output_integrate = TRUE,
      ppm = ppm, rt.tolerance = rt_tolerance, threads = threads, facet = FALSE
    )
    cat("[peak extraction] extract_targeted_peaks() finished for ", mode, ".\n", sep = "")
    flush(stdout())

    quant_path <- file.path(mode_dir, "IS_Extraction", "quantification_table.xlsx")
    if (!file.exists(quant_path)) stop("lipidflow did not produce a quantification table.")
    quant_table <- as.data.frame(readxl::read_xlsx(quant_path), stringsAsFactors = FALSE)

    # Extraction for the combined multi-adduct overlay chart - see
    # .lfs_extract_eic_traces()'s own header for why this can't just reuse
    # lipidflow's own internal raw traces. Caught separately (its own
    # tryCatch) so a failure here (e.g. an unusual raw file
    # xcms::chromatogram() can't handle) degrades to "no chart, Shape_Score
    # ranking falls back to Peak_Area alone" rather than losing the
    # already-computed, authoritative quant_table. Moved ahead of y_is_opt
    # (previously computed first) because the Adduct Scoring Algorithm now
    # needs these SAME traces to compute each candidate's Peak Shape
    # (Gaussian fit) score - see .lfs_score_candidates().
    cat("[peak extraction] extracting EIC traces for peak-shape scoring + the overlay chart...\n")
    flush(stdout())
    eic_data <- tryCatch({
      raw_object <- .lfs_read_raw_ms_file(qc_dest)
      .lfs_extract_eic_traces(raw_object, target_table, ppm = ppm, rt_window = NULL)
    }, error = function(e) {
      message("[utils_small_tools] EIC trace extraction failed (Peak Shape scoring falls back to Peak Area only): ",
              conditionMessage(e))
      NULL
    })
    cat("[peak extraction] EIC trace extraction done for ", mode, ".\n", sep = "")
    flush(stdout())

    # Automatic pick now uses the full Adduct Scoring Algorithm (0.6 x Peak
    # Shape + 0.4 x normalized Peak Area, see .lfs_score_candidates()) instead
    # of raw Peak_Area alone - eic_data may be NULL (EIC pass failed above),
    # in which case this gracefully degrades to the old Peak_Area-only
    # ranking (see .lfs_select_best_adduct_from_quant()'s header).
    y_is_opt <- .lfs_select_best_adduct_from_quant(quant_table, target_table, eic_data = eic_data)

    list(ok = TRUE, quant_table = quant_table, target_table = target_table, y_is_opt = y_is_opt,
         eic_data = eic_data, eic_dir = file.path(mode_dir, "IS_Extraction", "peak_shape"), message = NULL)
  }, error = function(e) {
    message("[utils_small_tools] Peak extraction (lipidflow) failed: ", conditionMessage(e))
    list(ok = FALSE, quant_table = NULL, target_table = NULL, y_is_opt = NULL, eic_data = NULL, eic_dir = NULL,
         message = conditionMessage(e))
  })
}
