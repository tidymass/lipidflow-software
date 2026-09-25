# Projects, reproducibility and troubleshooting

Each project has `project.json` and a separate `runs/<id>/` directory for every run. Records include inputs, parameters, upstream run ID, start/end times, status, request.json, worker.R, pinned helper copies, source revision metadata, run.log, sessionInfo.txt, object.rds and result tables. `reproduce.R` reruns a request using the same R packages; retained input paths must still be accessible.

Project writes use a lock and atomic replacement with a metadata backup. A project cannot be edited simultaneously by two app instances. If the app closes mid-run, the next open marks that run interrupted. Failed and cancelled runs are retained with logs. Successful earlier runs are never overwritten.

- **R environment:** shows whether bundled dependencies load and their versions.
- **Missing files:** restore original input paths or import again. Raw inputs are not silently relocated.
- **Missing standard / no class match:** compare names in Y_IS_opt and the concentration workbook; provide explicit class mapping if needed.
- **Zero standard area:** return to extraction and review candidates; zero cannot be used as a reliable denominator.
- **Too much memory:** use one worker and one polarity. POS and NEG already execute sequentially.
- **Unmatched annotations:** inspect the MS2 input, polarity, spectral library and matching tolerances.
- **macOS distribution:** this local build is an unsigned Apple Silicon preview, not an Apple-notarized public release.

Do not edit request.json or saved objects unless deliberately debugging/reproducing an analysis. Open external HTML/PDF plots only from trusted projects.

- **Windows distribution:** use the x64 setup installer. The bundled runtime requires no separate R installation. Builds are unsigned; verify the release checksum before installing.
