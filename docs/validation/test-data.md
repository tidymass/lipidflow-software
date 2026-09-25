# Validation data sources

These datasets test LipidFlow Desktop software behavior. Generated fixtures are not experimental datasets and do not establish scientific identification accuracy.

## Upstream raw POS examples

Source: [jaspershen-lab/lipidflow, revision 7a44a1f341973de2db81af6c9c191bf40e30a13e](https://github.com/jaspershen-lab/lipidflow/tree/7a44a1f341973de2db81af6c9c191bf40e30a13e/inst/POS).

- `inst/POS/M19/M19_1.mzXML`
- `inst/POS/M19/M19_2.mzXML`
- `inst/POS/D25/D25_1.mzXML`
- `inst/POS/D25/D25_2.mzXML`

`tests/raw-workflow.cjs` imports these four files and performs peak picking with ppm 15, peak width 10–60 seconds, S/N 5, noise 500, minimum fraction 0.5 and one worker. The current macOS reference run produced 13,848 aligned features. The automated assertion requires a nonempty final peak table; it does not assert identical feature counts across operating systems.

## Real internal-standard extraction

`tests/fixtures.R` takes the first standard's name, formula and accurate mass from the upstream `inst/POS/IS_information.xlsx`. `tests/engine.cjs --raw` and `tests/exploration-raw.cjs` extract `+H` and `+Na` from `M19_1.mzXML`, using 15 ppm. Checks cover two EIC traces, one final standard, saved manual selection, and ignoring a legacy comparison-sample input.

This real-data check covers one standard in POS. It is not a full internal-standard panel validation and does not cover real NEG raw files.

## Generated quantification fixture

`tests/fixtures.R` creates two artificial features, two sample columns, annotations and a known standard concentration. Assertions verify known ratios, including `2000 / 1000 × 20 = 40 µM` and `5000 / 1000 × 10 = 50 µg/mL`.

## Reference-derived annotation fixture

`tests/annotation-fixtures.R` selects two spectra from the bundled `msdial_lipid_pos_db.rda`, writes them to an MGF and generates matching feature inputs. In Windows installation tests, it reads the installed application's database. The test expects two annotation rows. This is a reference-match regression test, not validation against independent experimental MS2 queries.

## Generated interaction fixture

`tests/exploration-fixture.R` creates Gaussian curves for two standards, two adducts and two sample labels. The same synthetic values are used for POS and NEG to test polarity switching, sorting, visibility filters, zoom, manual override persistence and downloads. These synthetic NEG adduct labels are interface fixtures and are not a chemically valid negative-ion example.

The simulated comparison sample also checks compatibility with previously saved multi-sample results. The current extraction form accepts one QC file per polarity.

## 中文说明

真实原始数据来自固定版本的 LipidFlow 官方仓库，当前覆盖 POS 的四个 mzXML 文件。定量、参考谱匹配和交互测试还使用明确生成的测试数据。模拟峰形、重复用于两个 polarity 的数值及 adduct 标签仅用于功能回归，不能作为真实 NEG 实验验证。完整 POS/NEG 研究数据的科学验证仍需另行完成。
