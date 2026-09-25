# Run using system R only on the build machine. End users use the bundled R.
args <- commandArgs(TRUE)
stopifnot(.Platform$OS.type == 'windows', length(args) == 2)
lockfile <- normalizePath(args[1], winslash='/')
library_dir <- normalizePath(args[2], winslash='/')
options(repos=c(CRAN='https://cloud.r-project.org'), timeout=1200, Ncpus=2)
Sys.setenv(RENV_CONFIG_CACHE_ENABLED='FALSE', RENV_CONFIG_AUTOLOADER_ENABLED='FALSE')
bootstrap <- tempfile('lipidflow-build-tools-')
dir.create(bootstrap)
# Build tools are outside the application runtime.
install.packages('renv', lib=bootstrap)
.libPaths(c(bootstrap, .libPaths()))
lock <- renv::lockfile_read(lockfile)
if (as.character(getRversion()) != lock$R$Version) stop('Build with R ', lock$R$Version)
# Recommended packages can be resolved from system R without being copied by renv.
# They must exist at the locked versions inside the distributable library itself.
recommended <- rownames(installed.packages(lib.loc=.Library, priority='recommended'))
for (name in intersect(recommended, names(lock$Packages))) {
  record <- lock$Packages[[name]]
  current <- installed.packages(lib.loc=library_dir)
  if (!name %in% rownames(current) || current[name, 'Version'] != record$Version)
    renv::install(paste0(name, '@', record$Version), library=library_dir,
                  dependencies=FALSE, prompt=FALSE, rebuild=TRUE)
}
# Install bundled applications last: their upstream metadata may omit dependencies
# that their namespaces load, so parallel restoration must not start them early.
application_packages <- intersect('MetMiner', names(lock$Packages))
dependency_lock <- lock
dependency_lock$Packages[application_packages] <- NULL
dependency_file <- tempfile(fileext='.lock')
renv::lockfile_write(dependency_lock, dependency_file)
renv::restore(project=getwd(), library=library_dir, lockfile=dependency_file,
              prompt=FALSE, transactional=FALSE)
unlink(dependency_file)
renv::restore(project=getwd(), library=library_dir, lockfile=lockfile,
              prompt=FALSE, transactional=FALSE)
# A restore is not successful if any package silently moved to a different version.
p <- installed.packages(lib.loc=library_dir)
for (record in lock$Packages) {
  if (!record$Package %in% rownames(p) || p[record$Package,'Version'] != record$Version)
    stop('Runtime version mismatch: ', record$Package)
}
cat('Restored exact locked package versions.\n')
unlink(bootstrap, recursive=TRUE)
