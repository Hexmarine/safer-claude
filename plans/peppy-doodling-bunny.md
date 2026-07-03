# Plan — Restructure ml-battery-poc to notebooks-first (self-contained per-fold notebooks)

## Context

`code/ml-battery-poc/` is a guided predictive-maintenance learning course (battery
RUL via survival analysis, synthetic-first). It currently splits content across three
media: theory in `theory/*.md`, code in `src/*.py`, and thin plotext notebooks that
import the code. The user wants a single medium: **one self-contained notebook per
fold** holding *everything* — theory, worked proofs, the simulator code, the TODOs,
and the text-mode visuals — so a fold reads top-to-bottom as one artifact. The user
runs the notebooks and fills the TODOs on their side, then asks me to verify here.

Confirmed choices for the restructure:
- **Code reuse:** fully self-contained notebooks. The simulator lives *inline* in the
  fold that introduces it; that fold **saves its fleet to `data/*.parquet`**, and later
  folds **load** that dataset rather than re-running/duplicating code. No shared `src/`
  on the active path.
- **Math format:** ASCII / inline-code style (`h(t) = f(t)/S(t) = -d/dt log S(t)`),
  which renders identically in any terminal/euporie. No LaTeX.
- **Existing files:** keep `theory/*.md`, `src/*.py`, `GLOSSARY.md` as a **reference
  copy** (not deleted). Notebooks become canonical; the `.md`/`.py` may drift.

Why: a learning course is easier to follow, save, and reason about when each fold is one
scrollable document; the prior split forced context-switching between three files per fold.

## What stays the same (already decided, still valid)

- The **8-fold curriculum** and titles (below).
- **Intermediate math depth** with worked derivations; the **four TODO tags**
  (`[code]`/`[derive]`/`[predict]`/`[interpret]`); the **physics→stats→physics spine**
  (inject an Arrhenius `Ea` in Fold 2, recover it via an AFT fit in Fold 4).
- **plotext** for all visuals (text-mode); the `ml-battery-poc (.venv)` kernel.

## Canonical notebook anatomy (every fold notebook follows this)

1. **Header** — title, one-paragraph intent, the TODO legend, *Terms introduced*
   (links to `GLOSSARY.md`, kept as the consolidated reference).
2. **Setup cell** — imports (`numpy`, `pandas`, `plotext`), the `new_plot()` helper,
   `DATA = Path('../data')`.
3. **Theory cells** (markdown, ASCII math) — intuition → worked derivation → "why this
   matters" callout, with `[derive]` fill-in prompts embedded.
4. **Code cells** — the simulator/analysis *inline* (this is the canonical copy).
5. **Viz cells** — plotext plots, wrapped by `[predict]` (before) / `[interpret]` (after).
6. **Handoff cell** — the introducing fold writes `data/<fold>_fleet.parquet`
   (+ a small `data/<fold>_meta.json` for injected truth like `Ea`, configs); a
   consuming fold instead **loads** it, asserting existence with a friendly
   "run fold 0N first" message if missing.
7. **Next-fold pointer** (markdown).

**Single live `TODO(human)`.** It lives in the canonical *notebook* code cell. The
`src/*.py` reference copies have their `TODO(human)` markers neutralised to a pointer
comment (e.g. `# canonical TODO lives in notebooks/02_battery_physics.ipynb`) so the
repo has exactly one live human TODO at a time.

## Fold → notebook map

| Fold | Notebook (new naming) | Builds / consumes |
|---|---|---|
| 1 | `notebooks/01_discharge_and_time_to_event.ipynb` | builds **simple** sim inline → `data/fold1_fleet.parquet` |
| 2 | `notebooks/02_battery_physics.ipynb` | builds **physics** sim inline (the `ocv_from_soc` TODO) → `data/physics_fleet.parquet` |
| 3 | `notebooks/03_survival_foundations.ipynb` | loads physics fleet; S(t)/hazard/KM |
| 4 | `notebooks/04_parametric_models.ipynb` | loads physics fleet; Weibull AFT/Cox; recover `Ea` from `meta.json` |
| 5 | `notebooks/05_rul_prediction.ipynb` | loads fleet + fitted model approach |
| 6 | `notebooks/06_validation.ipynb` | loads fleet; C-index/Brier/calibration; ML vs threshold |
| 7 | `notebooks/07_bridge_to_reality.ipynb` | mapping to real MongoDB `BATTERY` events |

Naming convention: zero-padded `NN_snake_case.ipynb`. The old
`notebooks/01-discharge-simulator.ipynb` is **superseded** by `01_discharge_and_time_to_event.ipynb`
and removed (its content migrates in; the `theory/01*.md` + `src/simulator.py` reference
copies remain, so nothing is lost).

## Immediate next work (Folds 1 & 2 — the only folds with content yet)

### Tooling
- Add `pyarrow` to the venv + `requirements.txt` (parquet engine for the handoff).

### A. `01_discharge_and_time_to_event.ipynb` (restructure existing content into one notebook)
- Migrate `theory/01-discharge-and-time-to-event.md` into markdown cells (ASCII math):
  signal/threshold/RUL, the three censoring flavours, the `[derive]` selection-bias proof.
- Inline the **simple simulator** (`SimConfig`, `draw_devices`, `discharge_curve`,
  `simulate_telemetry`) from `src/simulator.py` as code cells — `discharge_curve` is
  already implemented (user's linear choice) so no live TODO here.
- Keep the existing plotext viz + the `[predict]`/`[interpret]` cells + the censoring-bias
  measurement (the −24%/−11% demo).
- Add the handoff cell: write `data/fold1_fleet.parquet`.
- Remove `notebooks/01-discharge-simulator.ipynb`.

### B. `02_battery_physics.ipynb` (new, self-contained — carries the live TODO)
- Migrate `theory/02-battery-physics.md` into markdown cells: SoC/SoH/OCV, the
  coulomb-counting `[derive]`, self-discharge, Arrhenius + acceleration factor, the
  Arrhenius→AFT spine.
- Inline the **physics simulator** (`PhysicsConfig`, `_gauge_pct`, `_temp_factor`,
  `_soc_at_threshold`, `draw_devices`, `simulate_physics_telemetry`) from
  `src/simulator_physics.py`, with **`ocv_from_soc` as the live `[code]` `TODO(human)`
  cell** (the user fills it here). `base_drain` already tuned to ~71% events.
- Viz: `[predict]` then plot the OCV knee; plot the resulting flat-then-cliff discharge
  vs Fold 1's straight line (load `data/fold1_fleet.parquet` for the overlay);
  `[interpret]` which is harder to forecast.
- Handoff: write `data/physics_fleet.parquet` + `data/physics_meta.json` (carry the
  injected `Ea` and config for Fold 4's recovery check).
- Neutralise the `TODO(human)` in `src/simulator_physics.py` to a pointer comment.

### Sequencing
1. Install `pyarrow`; update requirements.
2. Build `01_*.ipynb`; headless-execute; verify it writes `data/fold1_fleet.parquet`.
3. Build `02_*.ipynb` with the inline `ocv_from_soc` TODO; neutralise the src pointer;
   verify it gates on the TODO (raises until filled) using a stub, as before.
4. Hand `02_*.ipynb` to the user to implement `ocv_from_soc` inline; they save; I verify
   here (headless run, plots captured, parquet + meta written).
5. Later folds (3→7) are authored one at a time, each loading the upstream parquet.

## Files added / changed / removed (next work)

- New: `code/ml-battery-poc/notebooks/01_discharge_and_time_to_event.ipynb`
- New: `code/ml-battery-poc/notebooks/02_battery_physics.ipynb`
- Edit: `code/ml-battery-poc/requirements.txt` (+`pyarrow`)
- Edit: `code/ml-battery-poc/README.md` (notebooks-first layout + how-to-run)
- Edit: `code/ml-battery-poc/src/simulator_physics.py` (neutralise the duplicate TODO marker)
- Remove: `code/ml-battery-poc/notebooks/01-discharge-simulator.ipynb` (superseded)
- Keep (reference, unchanged): `theory/*.md`, `src/simulator.py`, `theory/GLOSSARY.md`

## Verification

- `\.venv/bin/python -c "import pyarrow"` succeeds.
- Headless execute each notebook:
  `\.venv/bin/jupyter nbconvert --to notebook --execute --inplace
  --ExecutePreprocessor.kernel_name=ml-battery-poc notebooks/0N_*.ipynb` → exit 0.
- Assert `data/fold1_fleet.parquet` and (after the user fills `ocv_from_soc`)
  `data/physics_fleet.parquet` + `data/physics_meta.json` exist and round-trip
  (`pd.read_parquet` → expected columns, no NaNs, sane event rate ~70%).
- Confirm plotext glyphs + ANSI captured in each plot cell's stream output.
- Confirm exactly one live `TODO(human)` repo-wide (`grep -rn "TODO(human)"`).
- User opens the notebooks in euporie (`ml-battery-poc (.venv)` kernel) and confirms
  theory + proofs + plots read well inline.

## Out of scope
- Real prod telemetry (Fold 7). Any Sensor product-code change. LaTeX math.
- Rewriting Folds 3–7 now (authored later, one at a time, same anatomy).
