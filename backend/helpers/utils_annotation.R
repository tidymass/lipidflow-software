# utils_annotation.R - shared helper for Lipid Annotation.
#
# IMPORTANT: annotation results are kept as 2 SEPARATE mass_dataset objects
# (POS, NEG) all the way through - never merged via massdataset::merge_mass_dataset().
# Same root cause as the Peak Picking fix: merging 2 mass_dataset S4 objects
# has an edge case that corrupts expression_data with small/unusual data,
# and utils_S.R (the confirmed-working reference script) never merges
# mass_dataset objects either - it keeps POS/NEG separate throughout and
# only combines plain data.frame results at the very end.
#
# This function is the safe equivalent: extract_annotation_table() is called
# separately on each already-valid mass_dataset (POS, NEG), producing 2
# ordinary data.frames, which ARE safe to combine with rbind() - unlike
# merging the S4 objects themselves.
.lfs_combined_annotation_table <- function(annotation_result) {
  tbl_pos <- .lfs_extract_flat_annotation_table(annotation_result$pos)
  tbl_neg <- .lfs_extract_flat_annotation_table(annotation_result$neg)
  if (is.null(tbl_pos)) return(tbl_neg)
  if (is.null(tbl_neg)) return(tbl_pos)
  rbind(tbl_pos, tbl_neg)
}

# ---------------------------------------------------------------------------
# One polarity's worth of what .lfs_combined_annotation_table() above used to
# do inline - pulled out on its own so mod_annotation.R can stage a flat,
# ALREADY-deduplicated (best candidate per feature) annotation table into
# pipeline_state$annotation_table_pos/neg the moment a live run finishes,
# without waiting for the user to visit Download Results. This flat table is
# also exactly what Step 3's .lfs_absolute_quant_from_tables()
# (utils_quantification.R) needs - it no longer touches the mass_dataset
# object at all, so Step 3 works identically whether this table came from a
# live Step 2 run or a re-uploaded annotation_table CSV (Data Import's "Skip
# to Absolute Quantification").
# Deduplicated PER POLARITY (not after an eventual POS+NEG rbind) -
# variable_id is only unique WITHIN one mass_dataset (POS and NEG come from
# separate Peak Picking runs), so deduplicating post-rbind would risk
# collapsing two genuinely different features that happen to share an id
# string across polarities. Falls back to the unfiltered table on any error
# rather than breaking the whole annotation view over a column-shape
# surprise in one edge case.
# ---------------------------------------------------------------------------
.lfs_extract_flat_annotation_table <- function(md) {
  if (is.null(md)) return(NULL)
  tbl <- tryCatch(massdataset::extract_annotation_table(md), error = function(e) md@variable_info)
  tryCatch(.lfs_best_candidate_per_feature(tbl), error = function(e) {
    message("[utils_annotation] .lfs_best_candidate_per_feature skipped: ", conditionMessage(e))
    tbl
  })
}

# ---------------------------------------------------------------------------
# Keep only the highest-scoring annotation candidate per feature (variable_id).
# metid::annotate_metabolites_mass_dataset() can return MULTIPLE candidate
# matches per feature (candidate.num controls how many, default 3 in this
# app) - without this filter, .lfs_combined_annotation_table() would show
# every candidate as its own row, not just the best one per feature. Ported
# from utils_S.R's best_candidate_per_feature() (the confirmed-working
# reference script), generalized into a pure/testable function here.
#
# Falls back to keeping the first row per feature (arbitrary but
# deterministic - matches utils_S.R's own fallback) when no recognizable
# score column is present, rather than erroring: an annotation table with no
# score column is unusual but not invalid input. Rows with a non-numeric or
# NA score are ranked last (-Inf), never preferred over a real score. Never
# mutates its input - subsetting/ordering in R always produces a new
# data.frame.
# ---------------------------------------------------------------------------
.lfs_best_candidate_per_feature <- function(annotation_table, feature_id_col = "variable_id",
                                             score_col_candidates = c("total.score", "Total.Score",
                                                                       "score", "Score",
                                                                       "ms2.score", "MS2.Score")) {
  if (!is.data.frame(annotation_table)) {
    stop(".lfs_best_candidate_per_feature: 'annotation_table' must be a data.frame.")
  }
  if (nrow(annotation_table) == 0) return(annotation_table)
  if (!feature_id_col %in% colnames(annotation_table)) {
    stop(".lfs_best_candidate_per_feature: annotation_table is missing column '", feature_id_col, "'.")
  }

  x <- annotation_table
  score_col <- score_col_candidates[score_col_candidates %in% colnames(x)]

  if (length(score_col) == 0) {
    out <- x[!duplicated(x[[feature_id_col]]), , drop = FALSE]
    rownames(out) <- NULL
    return(out)
  }

  score <- suppressWarnings(as.numeric(x[[score_col[1]]]))
  score[is.na(score)] <- -Inf

  x <- x[order(x[[feature_id_col]], -score), , drop = FALSE]
  out <- x[!duplicated(x[[feature_id_col]]), , drop = FALSE]
  rownames(out) <- NULL
  out
}

# ---------------------------------------------------------------------------
# Giai doan 2 matching formula, as a pure, vectorized, unit-testable
# function: Error (ppm) = |mz_measured - mz_theoretical| / mz_theoretical * 1e6.
# 'mz_theoretical' may be length 1 (recycled) or the same length as
# 'mz_measured'. Never mutates its inputs (returns a new numeric vector).
# ---------------------------------------------------------------------------
.lfs_calc_ppm_error <- function(mz_measured, mz_theoretical) {
  if (!is.numeric(mz_measured) || !is.numeric(mz_theoretical)) {
    stop(".lfs_calc_ppm_error: both 'mz_measured' and 'mz_theoretical' must be numeric.")
  }
  if (length(mz_theoretical) == 1 && length(mz_measured) > 1) {
    mz_theoretical <- rep(mz_theoretical, length(mz_measured))
  }
  if (length(mz_measured) != length(mz_theoretical)) {
    stop(".lfs_calc_ppm_error: 'mz_measured' and 'mz_theoretical' must be the same length ",
         "(or 'mz_theoretical' length 1).")
  }
  if (any(mz_theoretical <= 0, na.rm = TRUE)) {
    stop(".lfs_calc_ppm_error: 'mz_theoretical' must be strictly positive.")
  }
  abs(mz_measured - mz_theoretical) / mz_theoretical * 1e6
}

# ---------------------------------------------------------------------------
# Pure MS1 nearest-match annotator: for each peak, find the database entry
# with the smallest ppm error, keeping the match only if it's within
# tolerance_ppm (Giai doan 2's "Chi chap nhan <= tolerance ppm" rule).
# Implemented via outer() to build the full peak x database ppm-error
# matrix in one vectorized call, then apply()/which.min() per row - no
# manual nested for loop. Real MS2-aware annotation (metid) stays the
# primary path in mod_annotation.R; this is a lightweight, fully-testable
# MS1-only fallback/sanity-check matcher against a database table
# (columns: mz_theoretical, Lipid_Name by default).
# ---------------------------------------------------------------------------
.lfs_annotate_by_mz <- function(peak_table, database_table, tolerance_ppm = 5,
                                 peak_mz_col = "mz", db_mz_col = "mz_theoretical",
                                 db_name_col = "Lipid_Name") {
  if (!is.data.frame(peak_table) || !is.data.frame(database_table)) {
    stop(".lfs_annotate_by_mz: 'peak_table' and 'database_table' must both be data.frames.")
  }
  if (!peak_mz_col %in% colnames(peak_table)) {
    stop(".lfs_annotate_by_mz: peak_table is missing column '", peak_mz_col, "'.")
  }
  if (!all(c(db_mz_col, db_name_col) %in% colnames(database_table))) {
    stop(".lfs_annotate_by_mz: database_table is missing column '", db_mz_col,
         "' or '", db_name_col, "'.")
  }
  if (!is.numeric(tolerance_ppm) || length(tolerance_ppm) != 1 || is.na(tolerance_ppm) || tolerance_ppm <= 0) {
    stop(".lfs_annotate_by_mz: 'tolerance_ppm' must be a single positive number.")
  }

  result <- peak_table
  result$Lipid_Name <- rep(NA_character_, nrow(peak_table))
  result$ppm_error <- rep(NA_real_, nrow(peak_table))

  if (nrow(peak_table) == 0 || nrow(database_table) == 0) return(result)

  peak_mz <- peak_table[[peak_mz_col]]
  db_mz <- database_table[[db_mz_col]]
  if (!is.numeric(peak_mz) || !is.numeric(db_mz)) {
    stop(".lfs_annotate_by_mz: '", peak_mz_col, "' and '", db_mz_col, "' must both be numeric.")
  }

  ppm_matrix <- outer(peak_mz, db_mz, function(p, d) abs(p - d) / d * 1e6)
  best_idx <- apply(ppm_matrix, 1, function(row) {
    if (all(is.na(row))) return(NA_integer_)
    idx <- which.min(row)
    if (isTRUE(row[idx] <= tolerance_ppm)) idx else NA_integer_
  })

  matched <- !is.na(best_idx)
  if (any(matched)) {
    result$Lipid_Name[matched] <- database_table[[db_name_col]][best_idx[matched]]
    result$ppm_error[matched] <- ppm_matrix[cbind(which(matched), best_idx[matched])]
  }
  result
}

# ---------------------------------------------------------------------------
# Load the bundled MS-DIAL-derived metid database (data/msdial_lipid_pos_db.rda
# or _neg_db.rda) for a given polarity. Defaults to LFS_DEFAULT_DB_DIR (set
# in global.R) if db_dir isn't given explicitly, falling back to "<cwd>/data"
# so this also works when global.R hasn't been sourced (e.g. in tests).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Decide how many BiocParallel workers are worth spawning for a metid
# annotation run, given how many features (peaks) are being matched.
# metid's own metIdentification() (called whenever MS2 data is present -
# the normal path in this app) always builds a BiocParallel::SnowParam
# (Windows) / MulticoreParam (Mac/Linux) cluster sized by the `threads`
# value passed into annotate_metabolites_mass_dataset() - confirmed by
# reading metid 1.3.2's source directly. SnowParam's per-worker cost
# (spawning a new Rscript process + shipping the MS2 database/adduct table
# to it over a socket) is mostly fixed, so for a small feature count more
# threads makes annotation SLOWER, not faster.
#
# max_workers is a HARD ceiling independent of n_features/available_cores -
# added after a real incident: each SnowParam worker gets its OWN full copy
# of the shared MS2/database/adduct data shipped over its socket (not a
# lightweight fork on Windows), and for a real-sized spectral database that
# copy can be multiple GB. The pure features-per-worker heuristic below,
# uncapped, computed 15 "useful" workers for an 8235-feature/16-core run and
# actually spawned them - confirmed live: 14 RSOCKnode.R worker processes,
# ~10.7GB combined RSS, driving a 23GB-RAM machine down to 0.2GB free and
# into heavy swap-thrashing that LOOKED like a permanent hang (stuck for
# 30+ minutes) but was actually just catastrophically memory-starved.
# Capping the auto-detected count at a small, safe default protects users
# who never touch this setting; anyone with more RAM to spare can still
# force a higher count via the explicit `requested` override (the app's
# "Threads" field), which always wins regardless of this cap.
#
# per_worker_bytes/available_ram_bytes (both optional, NULL by default - a
# caller that omits them gets the exact old feature/core-only behavior,
# unchanged): a SECOND, RAM-aware ceiling on top of max_workers=4L, added
# because 4 is not actually a safe number in every case - it was picked as a
# broadly-reasonable default, not derived from any particular machine's real
# RAM budget. Confirmed by reading metid 1.3.2's own source
# (metid:::metIdentification()) that BiocParallel::bplapply()'s `...` extra
# arguments - ms1.info, ms2.info (the FULL MS2 spectra from the user's OWN
# uploaded raw MS2 file, not just the small reference database) and the
# filtered spectra.data - are shipped IN FULL to every single worker, not
# chunked. So the real per-run RAM cost is threads x per_worker_bytes, and
# per_worker_bytes scales with the USER'S OWN data (MS2 spectra count/size),
# which this function has no way to know from n_features alone - a small
# reference database with a huge user-uploaded MS2 file can still blow up 4
# workers just as badly as the original uncapped incident did. The point of
# this parameter pair is to let a caller who already has both numbers (e.g.
# mod_annotation.R, right after loading `database` and running mutate_ms2())
# fold them in automatically, so an ordinary user hitting this on Threads=0
# 'auto' never has to understand any of the above to get a safe outcome -
# manually lowering Threads should be a last resort for someone who knows
# what they're doing, not the only way anyone finds out this exists.
# ram_budget_fraction caps how much of the CURRENTLY-available system RAM
# (as reported by ps::ps_system_memory()$avail at call time - already net of
# whatever this same R process itself is holding, since per_worker_bytes is
# measured on an already-loaded database/md2) this function is willing to
# commit to ADDITIONAL worker copies; 0.5 (default) leaves roughly half of
# whatever's free as headroom for the rest of the annotation run + OS + every
# other app on the machine, deliberately conservative rather than tight.
#
# max_workers=4L / ram_budget_fraction=0.5 - reverted back to these (per
# direct agreement) after a brief 3L/0.35 tightening; the user preferred to
# keep the original, more permissive defaults (favoring speed on a
# well-resourced machine) and rely on per-run judgement (the "Threads" field)
# for anyone on a RAM-constrained machine instead.
#
# 'requested' is an explicit user override: 0/NA/NULL means "auto-detect";
# any positive number is returned as-is (the user knows what they want, and
# is accepting the memory cost that comes with it) - this still bypasses
# BOTH ceilings below, same as before.
# This is the pure/testable twin of the identical (duplicated, not called)
# auto_threads() inside mod_annotation.R's run_side() - duplicated there
# only because callr::r_bg() never sources this app's R/ files.
# ---------------------------------------------------------------------------
.lfs_auto_threads <- function(n_features, requested = NULL, os = .Platform$OS.type,
                               available_cores = NULL, max_workers = 4L,
                               per_worker_bytes = NULL, available_ram_bytes = NULL,
                               ram_budget_fraction = 0.5) {
  if (!is.null(requested) && !is.na(requested) && requested > 0) {
    return(as.integer(requested))
  }
  if (!is.numeric(n_features) || length(n_features) != 1 || is.na(n_features) || n_features < 1) {
    return(1L)
  }
  if (is.null(available_cores)) {
    available_cores <- max(1L, parallel::detectCores(logical = TRUE) - 1L)
  }
  # SnowParam (Windows) spawns real OS processes over sockets - much higher
  # fixed cost per worker than MulticoreParam's (Mac/Linux) fork(), so it
  # needs more features-per-worker to be worth it.
  min_features_per_worker <- if (identical(os, "windows")) 300L else 100L
  workers_useful <- floor(n_features / min_features_per_worker)
  workers <- max(1L, min(available_cores, workers_useful, max_workers))

  if (!is.null(per_worker_bytes) && is.numeric(per_worker_bytes) &&
      is.finite(per_worker_bytes) && per_worker_bytes > 0) {
    if (is.null(available_ram_bytes)) {
      available_ram_bytes <- tryCatch({
        if (requireNamespace("ps", quietly = TRUE)) as.numeric(ps::ps_system_memory()$avail) else NA_real_
      }, error = function(e) NA_real_)
    }
    if (is.numeric(available_ram_bytes) && is.finite(available_ram_bytes) && available_ram_bytes > 0) {
      workers_by_ram <- max(1L, floor((available_ram_bytes * ram_budget_fraction) / per_worker_bytes))
      workers <- min(workers, workers_by_ram)
    }
  }

  as.integer(workers)
}

# ---------------------------------------------------------------------------
# Case-insensitive "find the first matching column name" helper shared by
# the target-builder functions below - ported from utils_S.R's find_col().
# Returns NA_character_ (not an error) when nothing matches, since "this
# column doesn't exist" is a normal, checkable outcome for callers here, not
# a malformed-input error.
# ---------------------------------------------------------------------------
.lfs_find_col <- function(x, choices) {
  idx <- match(tolower(choices), tolower(names(x)), nomatch = 0L)
  idx <- idx[idx > 0L]
  if (length(idx)) names(x)[idx[1]] else NA_character_
}

# .lfs_add_feature_coordinates() / .lfs_make_lipidflow_targets() /
# .lfs_default_is_adduct() / .lfs_make_is_targets() (built target lists for
# lipidflow::extract_targeted_peaks() against raw files) were removed here -
# Step 3 no longer re-extracts from raw files at all, see
# utils_quantification.R's file header for the current (peak_table +
# annotation_table + Y_IS_opt join) approach.

.lfs_load_msdial_db <- function(mode = c("positive", "negative"), db_dir = NULL) {
  mode <- match.arg(mode)
  if (is.null(db_dir)) {
    db_dir <- if (exists("LFS_DEFAULT_DB_DIR", inherits = TRUE)) {
      get("LFS_DEFAULT_DB_DIR", inherits = TRUE)
    } else {
      file.path(getwd(), "data")
    }
  }
  fname <- if (mode == "positive") "msdial_lipid_pos_db.rda" else "msdial_lipid_neg_db.rda"
  path <- file.path(db_dir, fname)
  if (!file.exists(path)) {
    stop(".lfs_load_msdial_db: database file not found: ", path)
  }
  tryCatch({
    e <- new.env()
    load(path, envir = e)
    obj_names <- ls(e)
    if (length(obj_names) == 0) stop("no objects found in .rda file")
    get(obj_names[1], envir = e)
  }, error = function(e) {
    stop(".lfs_load_msdial_db: failed to load '", path, "': ", conditionMessage(e))
  })
}
