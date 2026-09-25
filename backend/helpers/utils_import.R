# Helper functions for mod_import.R - organizing uploaded/staged files into
# the layout massprocesser expects, inferring sample groups from filenames.
# Split out of the original utils_peak_picking.R (moved here verbatim, not rewritten)
# as part of the mod_/utils_ file reorganization.

# ---------------------------------------------------------------------------
# Infer a sample "group" from an original filename, e.g. "D25_1.mzXML" ->
# "D25", "M19-2.mgf" -> "M19", "D25.1.mzXML"/"D25.2.mzXML" -> "D25" - strips
# the file extension then a trailing "_<number>", "-<number>", or
# "."<number>" (the replicate index). Falls back to the full stem if no such
# pattern is found (each file becomes its own group of one).
#
# The "." separator matters as much as "_"/"-" here: tools::file_path_sans_ext()
# only strips the LAST extension, so "D25.1.mzXML" is already a real,
# supported filename shape (the app's own Module 4 spec's own canonical
# example) - its stem is "D25.1", and without "." in the character class
# below, the regex would only strip the trailing digit itself, leaving a
# stray "D25." group instead of "D25". Loosely matches "D25_1"/"D25-1"/
# "D25.1" alike since none of those separators carry other meaning in a raw
# MS filename.
# This only exists because the new upload-based flow has no folder structure
# to read a group from (a browser file picker flattens that) - so the group
# has to come from *somewhere*, and the filename convention already used in
# lipidflow's own demo data (D25_1, D25_2, M19_1, M19_2) is the least-new-
# concept way to get it. Real user files that don't follow this pattern will
# each land in their own single-sample group - noted in the UI.
# ---------------------------------------------------------------------------
.lfs_infer_group <- function(filename) {
  stem <- tools::file_path_sans_ext(filename)
  group <- sub("[_.-]?[0-9]+$", "", stem)
  if (!nzchar(group)) stem else group
}

# ---------------------------------------------------------------------------
# Accumulate one fileInput() batch (data.frame: name/size/type/datapath) onto
# whatever was already staged, de-duplicating by name. Pulled out of
# mod_import.R's observeEvent(input$files_pos/files_neg, ...) as its own pure
# function so a batch of many files (e.g. 15 mzXML files selected at once, or
# several smaller batches added one after another) can be unit-tested
# directly - there is no hardcoded cap on file count anywhere in this
# function; every row of `new` that isn't an exact name-duplicate of an
# already-staged row is kept. Never mutates `current`/`new`; always returns a
# new data.frame.
# ---------------------------------------------------------------------------
.lfs_accumulate_files <- function(current, new) {
  if (is.null(new) || nrow(new) == 0) return(current)
  if (is.null(current) || nrow(current) == 0) return(new)
  combined <- rbind(current, new)
  combined[!duplicated(combined$name), , drop = FALSE]
}

# ---------------------------------------------------------------------------
# Module 4 (Peak Picking Data Import): build the POS/NEG group-overview table
# shown above the file-preview - one row per inferred sample group (see
# .lfs_infer_group()'s D25_1/D25_2 -> "D25" regex above), with a POS file
# count, a NEG file count, and a Status flag. "Status" is "OK" only when a
# group has at least one file in BOTH polarities, since massprocesser expects
# every group to be run in both modes - a group with only POS or only NEG
# files is flagged "POS only"/"NEG only" so the user notices before running
# Step 1, not after it silently drops/mismatches that group.
# Returns list(summary = <group-level df>, children = <named list of
# per-group filename vectors>) - `children` feeds the expandable detail rows
# in mod_import.R's DT/reactable table; kept as a separate named list rather
# than a list-column so the pure grouping logic here has no rendering-layer
# dependency and is unit-testable on its own.
# ---------------------------------------------------------------------------
.lfs_build_pos_neg_group_summary <- function(pos_names, neg_names) {
  empty_summary <- data.frame(
    Group = character(), POS_Files = integer(), NEG_Files = integer(),
    Status = character(), stringsAsFactors = FALSE
  )
  if (length(pos_names) == 0 && length(neg_names) == 0) {
    return(list(summary = empty_summary, children = list()))
  }

  pos_group <- if (length(pos_names) > 0) vapply(pos_names, .lfs_infer_group, character(1)) else character()
  neg_group <- if (length(neg_names) > 0) vapply(neg_names, .lfs_infer_group, character(1)) else character()

  all_groups <- sort(unique(c(pos_group, neg_group)))
  pos_count <- vapply(all_groups, function(g) sum(pos_group == g), integer(1))
  neg_count <- vapply(all_groups, function(g) sum(neg_group == g), integer(1))
  status <- ifelse(pos_count > 0 & neg_count > 0, "OK",
             ifelse(pos_count > 0, "POS only", "NEG only"))

  summary <- data.frame(
    Group = all_groups, POS_Files = as.integer(pos_count), NEG_Files = as.integer(neg_count),
    Status = status, stringsAsFactors = FALSE
  )
  # vapply(pos_names, ...) above uses R's default USE.NAMES = TRUE behavior:
  # since pos_names/neg_names are plain character vectors, vapply names its
  # output with the filenames themselves, and those names ride along through
  # c()/unique()/sort() into all_groups. data.frame() then auto-adopts a
  # named vector's names as ROW NAMES - so without this reset, `summary`
  # would carry a stray filename-derived row name per group, which
  # reactable() (mod_import.R's group_table) auto-displays as an extra
  # leftmost column that looks like a near-duplicate of Group. Row names
  # carry no meaning here (rows are already keyed by the Group column), so
  # resetting to the default 1:n sequence is always correct, never lossy.
  rownames(summary) <- NULL

  children <- stats::setNames(
    lapply(all_groups, function(g) {
      data.frame(
        File = c(pos_names[pos_group == g], neg_names[neg_group == g]),
        Mode = c(rep("POS", sum(pos_group == g)), rep("NEG", sum(neg_group == g))),
        stringsAsFactors = FALSE
      )
    }),
    all_groups
  )

  list(summary = summary, children = children)
}


# ---------------------------------------------------------------------------
# Given a shiny fileInput() data.frame (columns: name, datapath, ...) for one
# polarity, copy each uploaded file into <root>/<mode>/<inferred group>/<original name>
# - the exact layout massprocesser::process_data() expects. Returns the
# inferred group -> file count mapping for display.
# ---------------------------------------------------------------------------
.lfs_organize_uploads <- function(files_df, root, mode) {
  groups <- character(nrow(files_df))
  for (i in seq_len(nrow(files_df))) {
    grp <- .lfs_infer_group(files_df$name[i])
    groups[i] <- grp
    dest_dir <- file.path(root, mode, grp)
    dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
    file.copy(files_df$datapath[i], file.path(dest_dir, files_df$name[i]), overwrite = TRUE)
    # Raw mzXML files can be GB-scale; reclaim transient R-level buffers
    # periodically (not after every single copy - gc() itself has a fixed
    # cost that adds up across a large multi-file batch) so peak memory
    # stays bounded without dominating total copy time.
    if (i %% 10 == 0) gc(verbose = FALSE)
  }
  gc(verbose = FALSE)
  table(groups)
}

# Simple flat-folder version of .lfs_organize_uploads() - no group inference,
# just copies every uploaded file into one folder under its original name.
# Used for MS2 file uploads (massdataset::mutate_ms2() just wants a folder).
.lfs_organize_uploads_flat <- function(files_df, dest_dir) {
  dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
  for (i in seq_len(nrow(files_df))) {
    file.copy(files_df$datapath[i], file.path(dest_dir, files_df$name[i]), overwrite = TRUE)
    if (i %% 10 == 0) gc(verbose = FALSE)
  }
  gc(verbose = FALSE)
  nrow(files_df)
}

# ---------------------------------------------------------------------------
# xlsx reading/validation helpers used by mod_import.R - moved here verbatim
# from utils_quant.R as part of the mod_/utils_ file reorganization.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# LipidSearch's native xlsx export prepends a metadata block before the real
# header row - one row per raw file, formatted like "#[c-1]:D25_1.raw".
# Confirmed directly against lipidflow's own bundled demo annotation tables
# (inst/POS/lipid_annotation_table_pos.xlsx: 26 such rows, real header
# "LipidIon, Class, FattyAcid, ..." at row 27; NEG file: same, 26 rows).
# Without accounting for this, reading row 1 as the header - which is what
# a plain read_xlsx() does - produces meaningless "...2, ...3, ..." column
# names instead of "Class", breaking the class-column picker entirely
# against real LipidSearch output, which is the primary annotation-table
# source lipidflow expects. Detected generically (read column 1 only, find
# the first row that isn't "#"-prefixed) so it works for any LipidSearch
# export, and correctly returns 0 (no skip) for a plain single-header-row
# file, e.g. one you built by hand rather than exported from LipidSearch.
# ---------------------------------------------------------------------------
.lfs_detect_header_skip <- function(filepath) {
  if (is.null(filepath) || !file.exists(filepath)) return(0)
  col1 <- tryCatch(
    suppressMessages(readxl::read_xlsx(filepath, col_names = FALSE))[[1]],
    error = function(e) NULL
  )
  if (is.null(col1)) return(0)
  hdr_row <- which(!startsWith(trimws(as.character(col1)), "#"))[1]
  if (is.na(hdr_row)) return(0)
  hdr_row - 1
}

# ---------------------------------------------------------------------------
# Read just the column names of an uploaded xlsx (fast, header-only) so the
# UI can ask "which column holds the lipid class?" instead of assuming a
# fixed schema - annotation tables commonly come from LipidSearch exports,
# whose exact column naming varies by version/export settings.
# ---------------------------------------------------------------------------
.lfs_xlsx_colnames <- function(filepath) {
  if (is.null(filepath) || !file.exists(filepath)) return(character())
  skip <- .lfs_detect_header_skip(filepath)
  df <- suppressMessages(readxl::read_xlsx(filepath, skip = skip, n_max = 0))
  colnames(df)
}

.lfs_unique_column_values <- function(filepath, column) {
  if (is.null(filepath) || !file.exists(filepath) || !nzchar(column)) return(character())
  skip <- .lfs_detect_header_skip(filepath)
  df <- suppressMessages(readxl::read_xlsx(filepath, skip = skip))
  if (!column %in% colnames(df)) return(character())
  sort(unique(stats::na.omit(as.character(df[[column]]))))
}

# lipidflow's own bundled demo IS_information.xlsx has trailing non-breaking
# spaces (U+00A0) on several `name` values, e.g. "15:0-18:1(d7) DAG\u00a0" -
# confirmed by inspecting the real file, not assumed. Exact-string matching
# against the plain-space defaults in .lfs_default_match_item_pos()/_neg()
# silently returns nothing for those classes otherwise (intersect() with no
# error, just an empty pre-fill - easy to miss). Used only for comparison;
# the real (un-normalized) string from is_names is still what gets selected
# and submitted, since that's what lipidflow needs to match internally.
.lfs_normalize_ws <- function(x) trimws(gsub("[\u00a0[:space:]]+", " ", x))

.lfs_is_names <- function(filepath) {
  if (is.null(filepath) || !file.exists(filepath)) return(character())
  df <- readxl::read_xlsx(filepath)
  if (!"name" %in% colnames(df)) return(character())
  sort(unique(stats::na.omit(as.character(df[["name"]]))))
}

# ---------------------------------------------------------------------------
# Validate an uploaded Internal Standard table has the 5 required columns
# (name, exact.mass, formula, ug_ml, um) - report exactly which ones are
# missing rather than a generic error, so the user can fix the file quickly.
# ---------------------------------------------------------------------------
.lfs_validate_is_table <- function(filepath) {
  required_cols <- c("name", "exact.mass", "formula", "ug_ml", "um")
  if (is.null(filepath) || !file.exists(filepath)) {
    return(list(ok = FALSE, message = "File not found."))
  }
  cols <- tryCatch(colnames(readxl::read_xlsx(filepath, n_max = 0)),
                   error = function(e) character())
  missing <- setdiff(required_cols, cols)
  if (length(missing) > 0) {
    return(list(ok = FALSE,
                message = paste0("Missing required column(s): ", paste(missing, collapse = ", "),
                                 ". Expected exactly: ", paste(required_cols, collapse = ", "), ".")))
  }
  list(ok = TRUE, message = NULL)
}

# ---------------------------------------------------------------------------
# Light validation for a "Load Existing Result" (Option B) peak-picking
# object upload BEFORE it's ever handed to a background job - mod_peak_picking.R
# used to just try load()-ing whatever was uploaded straight inside a callr
# job, so a wrong file (e.g. someone re-uploading the "peak_table.csv" export
# instead of the actual saved mass_dataset object) only surfaced as a cryptic
# R error deep in that job's log ("bad restore file magic number" etc.),
# which read exactly like "nothing works, I have to redo Peak Picking from
# raw files" even though the fix was just "upload the right file". This
# gives an immediate, specific notification the moment the file is chosen,
# and never trusts the file further than base R's own load() can verify -
# no guessing at the object's class beyond that.
# ---------------------------------------------------------------------------
.lfs_validate_existing_object <- function(filepath) {
  if (is.null(filepath) || !file.exists(filepath)) {
    return(list(ok = FALSE, message = "File not found."))
  }
  e <- new.env()
  loaded_names <- tryCatch(suppressWarnings(load(filepath, envir = e)), error = function(err) {
    structure(character(0), error = conditionMessage(err))
  })
  if (length(loaded_names) == 0) {
    err <- attr(loaded_names, "error")
    return(list(ok = FALSE,
                message = paste0(
                  "This doesn't look like a saved result object (.rda/.RData). ",
                  "If you downloaded the \"peak_table\" CSV from the Peak table tab, that alone can't be ",
                  "reloaded here - use the \"Download object (.rda)\" button instead, or (if you only have ",
                  "the CSV) use the separate \"Skip to Absolute Quantification\" upload fields below.",
                  if (!is.null(err)) paste0(" (", err, ")") else "")))
  }
  obj <- get(loaded_names[1], envir = e)
  if (!methods::is(obj, "mass_dataset")) {
    return(list(ok = FALSE,
                message = paste0("File loaded, but '", loaded_names[1], "' is a ", paste(class(obj), collapse = "/"),
                                 ", not a mass_dataset object - this isn't a valid Peak Picking result file.")))
  }
  list(ok = TRUE, message = NULL)
}

# ---------------------------------------------------------------------------
# 3 CSV readers for "Skip to Absolute Quantification" (Data Import) - let a
# user who already has peak_table/annotation_table/Y_IS_opt exports from
# previous runs jump straight to Step 3 without re-running Steps 1-2 or
# Small Tools, since Step 3's calculation (.lfs_absolute_quant_from_tables(),
# utils_quantification.R) only ever needs these as plain tables, never the
# original raw files or S4 objects. Each just needs the same column names
# their respective live download already produces (checked leniently via
# .lfs_find_col()-style aliases, not an exact match), so a file downloaded
# from this app's own Peak table / Annotation / Y_IS_opt export buttons
# re-uploads without any manual editing.
# check.names = FALSE preserves sample column headers exactly as exported
# (e.g. "D25_1.mzXML") - R's default check.names = TRUE would silently
# mangle a header starting with a digit or containing certain punctuation,
# which would then no longer match anything a user might cross-reference it
# against.
# ---------------------------------------------------------------------------
.lfs_read_existing_peak_table <- function(filepath) {
  if (is.null(filepath) || !file.exists(filepath)) return(list(ok = FALSE, message = "File not found.", data = NULL))
  df <- tryCatch(utils::read.csv(filepath, stringsAsFactors = FALSE, check.names = FALSE),
                 error = function(e) NULL)
  if (is.null(df)) return(list(ok = FALSE, message = "Could not read this file as CSV.", data = NULL))
  id_col <- .lfs_find_col(df, c("variable_id", "Variable.ID", "variable", "variableID"))
  if (is.na(id_col)) {
    return(list(ok = FALSE, message = "Missing a variable_id column - this doesn't look like a peak table export.", data = NULL))
  }
  mz_col <- .lfs_find_col(df, c("mz", "MZ", "mass_to_charge"))
  rt_col <- .lfs_find_col(df, c("rt", "RT", "retention_time", "retention time"))
  if (length(setdiff(colnames(df), c(id_col, mz_col, rt_col))) == 0) {
    return(list(ok = FALSE, message = "No sample (Peak_Area) columns found beyond variable_id/mz/rt.", data = NULL))
  }
  list(ok = TRUE, message = NULL, data = df)
}

.lfs_read_existing_annotation_table <- function(filepath) {
  if (is.null(filepath) || !file.exists(filepath)) return(list(ok = FALSE, message = "File not found.", data = NULL))
  df <- tryCatch(utils::read.csv(filepath, stringsAsFactors = FALSE, check.names = FALSE),
                 error = function(e) NULL)
  if (is.null(df)) return(list(ok = FALSE, message = "Could not read this file as CSV.", data = NULL))
  id_col <- .lfs_find_col(df, c("variable_id", "Variable.ID", "variable", "variableID"))
  name_col <- .lfs_find_col(df, c("Compound.name", "compound_name", "name", "Name"))
  if (is.na(id_col) || is.na(name_col)) {
    return(list(ok = FALSE,
                message = "Missing a variable_id and/or lipid-name column - this doesn't look like an annotation table export.",
                data = NULL))
  }
  list(ok = TRUE, message = NULL, data = df)
}

.lfs_read_existing_is_opt <- function(filepath) {
  if (is.null(filepath) || !file.exists(filepath)) return(list(ok = FALSE, message = "File not found.", data = NULL))
  df <- tryCatch(utils::read.csv(filepath, stringsAsFactors = FALSE, check.names = FALSE),
                 error = function(e) NULL)
  if (is.null(df)) return(list(ok = FALSE, message = "Could not read this file as CSV.", data = NULL))
  name_col <- .lfs_find_col(df, c("IS_Name", "is_name"))
  area_col <- .lfs_find_col(df, c("Peak_Area", "peak_area"))
  if (is.na(name_col) || is.na(area_col)) {
    return(list(ok = FALSE,
                message = "Missing IS_Name and/or Peak_Area column - this doesn't look like a Y_IS_opt export.",
                data = NULL))
  }
  list(ok = TRUE, message = NULL, data = df)
}