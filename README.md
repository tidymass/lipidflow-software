# LipidFlow Desktop

Standalone macOS and Windows lipidomics software based on TidyMass Desktop 0.1.65.

- One workflow: data import → peak picking → lipid annotation → absolute quantification → results/export.
- One analysis tool: Internal standard exploration from lipidflowshiny Small Tools.
- Electron + React + TypeScript, restricted IPC, isolated R processes, a bundled R runtime and independent LipidFlow application storage.

## Run and build

```sh
npm install
npm run build
npm start
npm test
npm run test:engine
npm run test:desktop
npm run pack
npm run pack:dmg
```

The existing `runtime/` directory contains the macOS Apple Silicon runtime. It must be supplied separately for a fresh clone. The `vendor/` directory contains the pinned upstream sources used during development. Runtime and vendor assets are local and ignored by Git.

Output: `release/mac-arm64/LipidFlow.app`.

## Documentation

Start at [docs/help/README.md](docs/help/README.md).

## Upstream revisions

- lipidflow: `7a44a1f341973de2db81af6c9c191bf40e30a13e`
- lipidflowshiny: `39a0a828dfae85d0820ef1dca937028760d855ef`

Helper implementations under backend/helpers are preserved from the Shiny repository. The desktop worker adapts their inputs and stores run artifacts; it does not replace the scientific algorithms. Internal-standard references remain polarity-specific. Quantification follows the current Shiny QC-area ratio method.

See [validation](docs/validation.md) for verification status and known limitations.

Additional validation commands (use the supplied vendor examples):

```sh
node tests/engine.cjs --raw
node tests/raw-workflow.cjs
runtime/R/bin/Rscript --vanilla tests/annotation-fixtures.R
node tests/annotation.cjs
```

`backend/helpers/zz_desktop_compat.R` contains narrowly scoped compatibility adapters for the inherited runtime: the MSnbase metadata constructor replacement already used by TidyMass, explicit-list MGF parsing for equal-length spectra, and precursor-mass matching for the supplied MS-DIAL libraries (retaining metid scoring and reference adducts). Scientific matching and quantification remain in the upstream packages.

## Windows

See [Windows build and validation](docs/development/windows.md). GitHub Actions builds a Windows x64 installer with its own R runtime and runs the shared tests against the installed application. Download the `lipidflow-windows-x64` artifact from a successful [Windows workflow run](https://github.com/tidymass/lipidflow-software/actions/workflows/windows.yml).
