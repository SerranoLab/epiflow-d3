# OmiQ import fixtures (NPC PAX6 / H3K27me3 spectral panel)

Tracked 2,000-row subsamples of the OmiQ exports used to validate the Import tab
(F4; data contract R21, cofactors R32). Built by `tools/make_omiq_fixtures.R`
(seed 42) from the full exports, which are **not** tracked: they live in `OMIQ/`
at the repo root (git-ignored), the folder `test_omiq_import.R` reads through
`EPIFLOW_OMIQ_FIXTURES` (default `OMIQ`); without it the full-file blocks print
`[SKIP]`.

| Fixture | Full export (under `OMIQ/`) | `_OMIQ-context.txt` | Rows (full) |
|---|---|---|---|
| `npc_raw.csv` | `npc_raw/8_files_concat-183012389097095_27.csv` | `Workflow name: MAS_Data Prep for D3 - S8, ID: 183012389097095` / `Task name: Export Data raw, ID: 27` | 188,056 |
| `npc_scaled.csv` | `npc_scaled/8_files_concat-183012389097095_28.csv` | `Workflow name: MAS_Data Prep for D3 - S8, ID: 183012389097095` / `Task name: Export Data, ID: 28` | 188,056 |
| `npc_blank_raw.csv` | `npc_blank_raw/npc_blank_raw.csv` | `Workflow name: MAS_Data Prep for D3 - S8, ID: 183012389097095` / `Task name: Export Data raw, ID: 16` | 217,674 |
| `npc_blank_scaled.csv` | `npc_blank_scaled/npc_blank_scaled.csv` | `Workflow name: MAS_Data Prep for D3 - S8, ID: 183012389097095` / `Task name: Export Data, ID: 15` | 217,674 |
| `npc_scaling.csv` | `Scaling-183012389097095-17.csv` (whole) | — | 280 features |

Tasks 27 / 28 are the stained-only export (8 FCS files, per-file capped at
24,732 cells); tasks 15 / 16 are the earlier export that adds `14-Blank.fcs`
(7,682 unstained cells) and more cells for three stained files. Both share the
15-column header: `Orig_Row_Number`, twelve `Primary___Secondary` channels
(six `^H3` marks, Caspase3, CyclinD1, Ki67, `Pax6 PE`, `FxCycle Violet` (DNA),
`PhH3`), `OmiqFilter` (PAX6+ / PAX6-), `OmiqFileIndex` (the FCS filename).
`Orig_Row_Number` restarts per file: the row key is `(OmiqFileIndex,
Orig_Row_Number)`, and a raw / scaled pair here carries exactly the same keys.

The scaled export equals `asinh(raw / Cofactor)` with the per-channel cofactor
whose `Feature Name (Primary)___Feature Name (Secondary)` matches the column
header (R21 validation: max |diff| 9e-5 at the export's 5-significant-digit
rounding). Cofactors on this panel: 6000 for ten markers, 600 for FxCycle
Violet, 1000 for Pax6 PE.

Sample sheet used by the tests (`npc_sample_sheet.csv`): genotype from the
filename token `180+.-` (KMT2D-) vs `180+.+` (KMT2D+), replicate from the
trailing token, condition = `NPC`, identity from the `OmiqFilter` column,
`14-Blank.fcs` with `role = blank`.
