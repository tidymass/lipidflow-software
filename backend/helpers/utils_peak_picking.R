# Helper functions for mod_peak_picking.R.
#
# Deliberately kept separate from utils_quant.R even though there's some
# overlap with .lfs_validate_path_structure() (both check POS/NEG + mzXML
# presence) - massprocesser needs no config xlsx files, so unifying the two
# checkers would mean threading a bunch of "is this check relevant here"
# flags through one function. Some duplication, but each function stays
# readable. Worth revisiting once a third module needs the same checks.

# ---------------------------------------------------------------------------
# Decide how many BiocParallel workers are worth spawning for a Peak Picking
# side (POS or NEG). massprocesser::process_data() builds a
# BiocParallel::SnowParam(workers = threads) (Windows) / MulticoreParam
# (Mac/Linux) cluster and hands it to xcms::findChromPeaks(), which
# parallelizes per RAW FILE - so more workers than files just spins up idle
# processes (each a real Rscript.exe on Windows) for no benefit, and more
# workers than the machine actually has spare cores oversubscribes CPU/RAM.
#
# 'requested' is an explicit user override: 0/NA/NULL means "auto-detect";
# any positive number is returned as-is (the user knows what they want, and
# is accepting the memory cost that comes with it).
# 'available_cores' is the caller's job: when POS and NEG are both being
# launched on the same click, the caller should split its own
# detectCores()-based budget between the two calls (e.g. floor(cap / 2))
# before calling this - otherwise two full-budget sides running at once
# oversubscribe the machine just as badly as a fixed high thread count did.
#
# max_workers is a HARD ceiling independent of n_files/available_cores - same
# fix, same rationale, as .lfs_auto_threads()'s identical parameter
# (utils_annotation.R): each SnowParam worker here is a real Rscript.exe that
# has to hold its own raw file's chromatographic data in memory while
# xcms::findChromPeaks() runs on it, and a real annotation run on this same
# app spawned 14-15 uncapped auto-detected workers, driving a 23GB-RAM
# machine down to 0.2GB free (confirmed live via Task Manager) - Peak
# Picking's own auto-detection had the exact same "scale with file/core
# count only, ignore memory" shape, just not yet caught live. requested
# (the app's "Threads" field) always still wins over this cap.
#
# Unlike .lfs_auto_threads() (utils_annotation.R), this has no duplicate
# copy inside a callr::r_bg() job body: the file count is known upfront on
# the main thread (from pipeline_state$pp_files_pos/neg or a directory
# listing), so mod_peak_picking.R computes the thread count once here and
# passes it into pos_args$threads/neg_args$threads as a plain integer.
#
# per_worker_bytes/available_ram_bytes (both optional, NULL by default -
# omitting them reproduces the exact old file/core-only behavior): a SECOND,
# RAM-aware ceiling, added for the same reason as .lfs_auto_threads()'s
# (utils_annotation.R) equivalent - max_workers=4L was picked as a
# broadly-reasonable guess, not derived from any particular machine's real
# RAM budget. IMPORTANT DIFFERENCE from Annotation's metid-based worker pool
# though (confirmed by reading massprocesser 1.0.11's own process_data()
# source, not assumed to be "the same kind of problem" just because both use
# BiocParallel::SnowParam): massprocesser hands xcms::findChromPeaks() an
# ONDISK MSnExp object (mode = "onDisk"), so each SnowParam worker streams
# and processes only the file(s) it's assigned FROM DISK - there is no
# single shared object (spectral database, MS2 spectra, etc.) getting
# shipped in full to every worker the way metid's bplapply() does. So this
# ceiling is genuinely lower-stakes than Annotation's: worker count already
# can't exceed n_files (a worker with no file to process is just idle, never
# an extra full copy of shared data), and per-worker RAM cost scales with
# ONE file's own footprint, not a large shared payload multiplied by thread
# count. Still worth the same safety net for genuinely large raw files.
# per_worker_bytes is meant to be the file's SIZE ON DISK (cheap to know
# upfront - already present as fileInput's own `size` column for uploads, or
# a plain file.info() call for a server path) used AS-IS with no invented
# expansion factor: xcms's onDisk mode keeps most of a file's data on disk
# rather than materializing it all in R memory, so on-disk file size is
# already a conservative (if anything, an over-) estimate of actual RSS per
# worker, not an under-estimate that would need inflating.
# ---------------------------------------------------------------------------
.lfs_auto_threads_pp <- function(n_files, requested = NULL, available_cores = NULL, max_workers = 4L,
                                  per_worker_bytes = NULL, available_ram_bytes = NULL,
                                  ram_budget_fraction = 0.5) {
  if (!is.null(requested) && !is.na(requested) && requested > 0) {
    return(as.integer(requested))
  }
  if (!is.numeric(n_files) || length(n_files) != 1 || is.na(n_files) || n_files < 1) {
    return(1L)
  }
  if (is.null(available_cores)) {
    available_cores <- max(1L, parallel::detectCores(logical = TRUE) - 1L)
  }
  workers <- max(1L, min(available_cores, as.integer(n_files), max_workers))

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
# Pre-flight check mirroring what massprocesser::process_data() actually
# needs: POS/NEG folders, each with at least one .mzXML/.mzML file somewhere
# under it. Unlike lipidflow's quantification step, there's no required
# config file and no hard requirement on group_for_figure existing -
# process_data() degrades gracefully (picks a substitute group) if the
# requested one isn't found, so that's surfaced as an informational note
# in the UI rather than a blocking check here.
# ---------------------------------------------------------------------------
.lfs_validate_peak_picking_structure <- function(path) {
  add <- function(rows, check, ok, message) {
    rbind(rows, data.frame(check = check, status = ifelse(ok, "ok", "fail"),
                           message = message, stringsAsFactors = FALSE))
  }
  rows <- data.frame(check = character(), status = character(),
                     message = character(), stringsAsFactors = FALSE)
  
  if (!nzchar(path) || !dir.exists(path)) {
    rows <- add(rows, "Data folder exists", FALSE, paste0("Folder not found on the server: ", path))
    return(rows)
  }
  rows <- add(rows, "Data folder exists", TRUE, path)
  
  check_mode <- function(rows, mode) {
    mode_dir <- file.path(path, mode)
    ok_dir <- dir.exists(mode_dir)
    rows <- add(rows, paste0(mode, "/ subfolder"), ok_dir,
                if (ok_dir) "found" else paste0("massprocesser needs a ", mode, "/ subfolder"))
    if (ok_dir) {
      raw_files <- list.files(mode_dir, pattern = "\\.(mzXML|mzML|cdf|mgf)$",
                              recursive = TRUE, ignore.case = TRUE)
      rows <- add(rows, paste0(mode, ": raw files"), length(raw_files) > 0,
                  if (length(raw_files) > 0) paste(length(raw_files), "file(s) found")
                  else "no .mzXML/.mzML/.cdf files found anywhere under this folder")
    }
    rows
  }
  
  rows <- check_mode(rows, "POS")
  rows <- check_mode(rows, "NEG")
  rows
}

# ---------------------------------------------------------------------------
# Pure, testable core of .lfs_peak_table() below: merge a variable_info
# data.frame (must have a 'variable_id' column - Peak_ID/m/z_mean/RT_peak in
# the pipeline's terms) with an expression_data matrix/data.frame (one row
# per variable_id, one column per sample - Peak_Area). Row order is matched
# on variable_id, never assumed - see Chunk 1 discussion in project notes.
# Split out from .lfs_peak_table() so it can be unit-tested against plain
# data.frames/matrices, without needing a real S4 mass_dataset object.
# Vectorized (match() + cbind()); never mutates variable_info/expression_data,
# always returns a new data.frame.
# ---------------------------------------------------------------------------
.lfs_merge_variable_expression <- function(variable_info, expression_data) {
  if (is.null(variable_info) || !is.data.frame(variable_info)) {
    stop(".lfs_merge_variable_expression: 'variable_info' must be a data.frame.")
  }
  if (!"variable_id" %in% colnames(variable_info)) {
    stop(".lfs_merge_variable_expression: 'variable_info' must contain a 'variable_id' column.")
  }
  if (is.null(expression_data)) {
    stop(".lfs_merge_variable_expression: 'expression_data' must not be NULL.")
  }

  expr <- as.data.frame(expression_data, check.names = FALSE)
  if (is.null(rownames(expr)) || !any(nzchar(rownames(expr)))) {
    stop(".lfs_merge_variable_expression: 'expression_data' must have row names matching 'variable_id'.")
  }

  missing_ids <- setdiff(variable_info$variable_id, rownames(expr))
  if (length(missing_ids) > 0) {
    stop(".lfs_merge_variable_expression: expression_data is missing row(s) for variable_id(s): ",
         paste(utils::head(missing_ids, 5), collapse = ", "),
         if (length(missing_ids) > 5) ", ..." else "")
  }

  expr_ordered <- expr[match(variable_info$variable_id, rownames(expr)), , drop = FALSE]
  cbind(variable_info, expr_ordered)
}

# Merge variable_info + expression_data into 1 flat table (match() by
# variable_id, not row order - see Chunk 1 discussion). This is the ONLY
# place this merge should happen - every UI location that shows a peak
# table calls this, so display and download can never drift apart.
.lfs_peak_table <- function(mass_dataset_obj) {
  tryCatch({
    var_info <- mass_dataset_obj@variable_info
    expr_data <- mass_dataset_obj@expression_data
    .lfs_merge_variable_expression(var_info, expr_data)
  }, error = function(e) {
    message("[utils_peak_picking] .lfs_peak_table failed: ", conditionMessage(e))
    stop(e)
  })
}

# ---------------------------------------------------------------------------
# Estimate a coarse 0-100 progress percentage for a running callr background
# job by counting how many of an ordered list of expected log milestones
# (plain substrings that job's own cat() calls are known to print, e.g.
# "=== POS ===") have shown up so far in its accumulated stdout/stderr log
# text. massprocesser/metid don't expose a real per-item progress callback,
# so this is intentionally coarse (milestone count, not work-unit tracking) -
# but it turns the busy overlay from a static spinner into a determinate bar
# that visibly advances, which is what withProgress()/waiter would otherwise
# be used for (see mod_peak_picking.R / mod_annotation.R poll observers).
# Pure string matching, no I/O; never errors on empty/NULL/no-milestone
# input (returns 0).
# ---------------------------------------------------------------------------
.lfs_estimate_progress <- function(log_text, milestones) {
  if (is.null(log_text) || !nzchar(log_text) || length(milestones) == 0) return(0)
  hits <- vapply(milestones, function(m) grepl(m, log_text, fixed = TRUE), logical(1))
  round(100 * sum(hits) / length(milestones))
}

# ---------------------------------------------------------------------------
# Generic background-job launcher - same shape as .lfs_run_quant_job() in
# utils_quant.R, kept as its own small function here so this file has no
# dependency ordering requirement on utils_quant.R being sourced first.
# ---------------------------------------------------------------------------
.lfs_run_bg_job <- function(func, args, log_path) {
  callr::r_bg(func = func, args = args, stdout = log_path, stderr = log_path,
              supervise = TRUE, libpath = .libPaths())
}
