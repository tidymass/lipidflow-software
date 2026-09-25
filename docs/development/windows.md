# Windows build and validation

Windows x64 uses the same React UI, Electron IPC, R worker, scientific helpers and databases as the macOS 0.1.12 baseline. It includes the complete workflow, internal-standard review with manual adduct confirmation, downloads, recent projects and Wang Lab branding.

## Build

Use Windows x64, Node 22, Python 3.12, R 4.5.2 and Rtools45. From a fresh checkout:

```powershell
npm ci
npm run test:core
npm run bundle:r:windows
npm run pack:windows
```

The Windows runtime is restored from `packaging/r-packages.lock.json`, generated from the macOS package versions. The unused MetMiner Shiny application inherited from TidyMass is excluded; no LipidFlow analysis function depends on it. Native packages are built for Windows; macOS binaries are never copied. The restore verifies every package version and writes source, license and native-binary manifests. End users do not need R, Rtools or Node.

The unsigned per-user installer is written to `release/windows/LipidFlow-0.1.12-windows-x64-setup.exe`. Windows may display a publisher warning because no signing certificate is configured. Projects and application settings are preserved on uninstall.

## Automated acceptance checks

`.github/workflows/windows.yml` builds on Windows Server 2022, installs into a path with spaces and Unicode, and runs the shared engine and desktop tests against the installed resources. Tests cover quantitative values, real mzXML extraction and peak picking, reference-spectrum annotation, review controls, manual choices and download outputs. The test source data are fetched from the pinned lipidflow revision in the workflow. Installer artifacts are uploaded only after these checks pass; release events attach the tested installer and SHA256 checksum to that release.

## Updating the shared baseline

After intentionally updating the macOS runtime, run `npm run snapshot:runtime` on macOS and review the lockfile changes. Locally installed packages without source provenance require a commit-pinned entry in `packaging/r-source-overrides.json`. Do not substitute newer package versions only on Windows.
