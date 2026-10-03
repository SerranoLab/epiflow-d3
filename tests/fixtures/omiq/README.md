# OmiQ import fixtures (NPC PAX6 / H3K27me3 spectral panel)

Tracked 2,000-row subsamples of the OmiQ exports used to validate the Import tab
(F4; data contract R21, cofactors R32). Built by `tools/make_omiq_fixtures.R`
(seed 42) from the full exports, which are **not** tracked: they live in `OMIQ/`
at the repo root (git-ignored), the folder `test_omiq_import.R` reads through
`EPIFLOW_OMIQ_FIXTURES` (default `OMIQ`); without it the full-file blocks print
`[SKIP]`.

| Fixture | Full export (under `OMIQ/`) | `_OMIQ-context.txt` | Rows (full) |
|---|---|---|---|
| `npc_raw.csv` | `npc_raw/8_files_concat-183012389097095_38.csv` | `Workflow name: MAS_Data Prep for D3 - S8, ID: 183012389097095` / `Task name: Export Data raw, ID: 38` | 124,105 |
| `npc_scaled.csv` | `npc_scaled/8_files_concat-183012389097095_39.csv` | `Workflow name: MAS_Data Prep for D3 - S8, ID: 183012389097095` / `Task name: Export Data, ID: 39` | 124,105 |
| `npc_blank_raw.csv` | `npc_raw_blank/9_files_concat-183012389097095_42.csv` | `Workflow name: MAS_Data Prep for D3 - S8, ID: 183012389097095` / `Task name: Export Data raw, ID: 42` | 129,269 |
| `npc_blank_scaled.csv` | `npc_scaled_blank/9_files_concat-183012389097095_43.csv` | `Workflow name: MAS_Data Prep for D3 - S8, ID: 183012389097095` / `Task name: Export Data, ID: 43` | 129,269 |
| `npc_scaling.csv` | `Scaling PAX6 1000-183012389097095-29.csv` (whole) | — | 281 features |

Tasks 38 / 39 are the stained-only export (8 FCS files); tasks 42 / 43 add
`14-Blank.fcs` (unstained cells). All four share the 15-column header:
`Orig_Row_Number`, twelve `Primary___Secondary` channels (six `^H3` marks,
Caspase3, CyclinD1, Ki67, `Pax6 PE`, `FxCycle Violet` (DNA), `PhH3`),
`OmiqFilter` (the OmiQ gate path of each cell: `Data cleanup 2/PAX6+`,
`Data cleanup 2/PAX6-`, `Apoptotic`, `Low H3_PTM Cells`), `OmiqFileIndex`
(the FCS filename).
`Orig_Row_Number` restarts per file: the row key is `(OmiqFileIndex,
Orig_Row_Number)`, and a raw / scaled pair here carries exactly the same keys.

The scaled export equals `asinh(raw / Cofactor)` with the per-channel cofactor
whose `Feature Name (Primary)___Feature Name (Secondary)` matches the column
header (max |diff| below 1e-4 at the export's 5-significant-digit rounding;
`test_omiq_import.R` re-checks it). Cofactors in the task-29 Scaling CSV: 6000
for ten markers, 600 for FxCycle Violet, **1000 for Pax6 PE**.

History. A first export set (tasks 27 / 28, `Scaling-183012389097095-17.csv`,
Pax6 PE cofactor 9900) existed and was superseded on 2 October 2026: the
larger cofactor hid the PE negatives' spread, so the data were re-exported at
1000 (see DECISIONS R32, help-text note, with Roederer 2001 and Parks 2006).

Sample sheet used by the tests (`npc_sample_sheet.csv`; columns `file,
condition, genotype, replicate, identity, role`): genotype is the filename's
second token verbatim (`180+.-`, four files; `180+.+`, four files), replicate
the trailing token (`33-A`, `32`, `34`, `33-B`, `16.20`, `16.18`, `16.19`,
`16.16`), condition `NPC`, identity `OmiqFilter` (= take it from that export
column, per cell), and `14-Blank.fcs` has `role = blank` with the other fields
empty.
