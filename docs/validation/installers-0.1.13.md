# Demo-free installers, 0.1.13

Both macOS ARM64 and Windows x64 exclude only the lipidflow package's POS/NEG example directories. These contain example raw files and spreadsheets. Application functions, R dependencies and the two MS-DIAL reference databases remain bundled. The post-pack hook checks the actual packaged contents; the installed engine suite repeats that check.

## macOS ARM64

- DMG: `LipidFlow-0.1.13-mac-arm64.dmg`, 870,255,397 bytes (829.9 MiB).
- Previous 0.1.12 DMG: 1,089,626,749 bytes (1,039.1 MiB). Reduction: 20.1%.
- SHA256: `993202f6701b9c87c2b5c0e0b7f80f2bb1c8b6890d99d2cb31ba478bb4f53029`.
- DMG checksum verification passed. Mounted read-only contents report 0.1.13 and contain no lipidflow POS/NEG demo directories; both analysis databases remain present.
- Packaged engine tests passed: environment, table import, known-ratio quantification, export, real QC extraction, manual selection, QC-only compatibility, four-file real POS peak picking and reference-derived annotation.
- Packaged desktop test passed: navigation, saved project reopen and live R quantification.

## Windows x64

- Tested source: `c31d6d06601f372cc3907088a1bac6f0b98ac8b8`.
- [Successful Windows job](https://github.com/tidymass/lipidflow-software/actions/runs/36111917342/job/107997087664), duration 30m 47s.
- [Installer and SHA256 artifact](https://github.com/tidymass/lipidflow-software/actions/runs/36111917342/artifacts/10854391217), 834 MB as displayed by GitHub (previous 0.1.12 artifact: 1.02 GB).
- [Test evidence](https://github.com/tidymass/lipidflow-software/actions/runs/36111917342/artifacts/10854506182).
- Passed: core tests, package-content exclusion check, installation into a Unicode/space-containing path, installed-content exclusion check, all installed analysis tests, desktop/review/download regression and checksum generation.
- Windows tests use the GitHub Windows Server 2022 x64 runner. No separate physical Windows 10/11-machine validation is claimed. GitHub artifact downloads require repository access and are subject to retention limits.

## Footprint interpretation

After excluding demo data, the macOS app's uncompressed R directory is about 1,320 MiB, compared with 1,308 MiB in the current local TidyMass runtime. Electron frameworks occupy about 286 MiB; the two LipidFlow annotation databases together occupy only 18 MiB. Removing the annotation databases cannot account for a several-hundred-MB installer difference. Comparisons with an older 500–600 MB TidyMass installer require matching the exact version, architecture and compression settings; no such comparison was established here.

Validation source data and limitations are described in [test-data provenance](test-data.md). The installer is unsigned.
