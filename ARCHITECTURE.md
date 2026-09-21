# ARCHITECTURE.template.md

> **How to use:** copy this file into a repo as `ARCHITECTURE.md`.
> Delete the EXAMPLE block. Fill in the TEMPLATE block for that repo.
> Sections 3, 4, 5 are optional -- skip entirely if not applicable to the repo.

---

# ████ EXAMPLE — data-darwin-mlops-beagle ████
# ████ DELETE THIS ENTIRE BLOCK BEFORE COMMITTING ████

## 1. Repo Map

**Purpose:** ML habitat classification pipeline. Trains and evaluates models (UNet, LightGBM, Prithvi)
on multi-temporal satellite imagery to map vegetation habitats across European protected areas.
Runs on GCP Cloud Build + Compute Engine VMs. The agent never guesses run state -- it reads
`scripts/inspect_run.py` or GCS artifacts directly.

**Structure:**

| Path | Type | Purpose |
|------|------|---------|
| `.darwin/repo.json` | file | Identity manifest |
| `AGENTS.md` | file | Agentic context -- read first every session |
| `src/` | dir | Core pipeline code (s0 label sampling → s1 data prep → s4 analytics) |
| `scripts/` | dir | Inspection + analysis entrypoints (`inspect_run.py`, `build_data_inventory.py`) |
| `configs/` | dir | Per-campaign YAML + habitat mapping JSONs |
| `cicd/` | dir | Cloud Build trigger configs |
| `model/` | dir | Model definitions and training loops |
| `campaigns/` | dir | Per-campaign AOI definitions and split manifests |

**Entry points:**

| Entry point | Triggered by | What it does |
|-------------|-------------|--------------|
| `1-cloudbuild-chip-generation-vm.yaml` | Cloud Build trigger | Generates image chips from raw rasters |
| `2-cloudbuild-ml-unet-baseline-vm.yaml` | Cloud Build trigger | Trains UNet baseline model on VM |
| `scripts/inspect_run.py` | manual | Ground-truth check for any run's metrics, split, config |

**External dependencies:**

| Dependency | Type | Declared in |
|-----------|------|-------------|
| `darwin-agent-center` | MCP | `CLAUDE.md` |
| `gcloud` CLI | infra tool | `cicd/*.yaml`, `scripts/` |
| `gsutil` | infra tool | `src/`, `scripts/` |

## 2. Database Map

**GCP resources:**

| Resource | Type | Found in | Notes |
|---------|------|---------|-------|
| `gs://darwin-general-beagle/` | GCS bucket | `src/s1_data_preparation/build_prithvi_features.py:41` | Root bucket -- all data, experiments, models |
| `gs://darwin-general-beagle/Laboratory/Data/BAP/` | GCS path | `src/s1_data_preparation/build_prithvi_datacube.py:88` | Best Available Pixel composites per campaign |
| `gs://darwin-general-beagle/Laboratory/Experiments/prithvi/data/` | GCS path | `scripts/run_prithvi_features.py:17` | Prithvi feature tensors (read + write) |
| `gs://darwin-general-beagle/Laboratory/Experiments/<MODEL_ID>/` | GCS path | `scripts/inspect_run.py:12` | Per-run artifacts: model_metadata.json, split_summary.json, logs |
| `artifacts/split_summary.json` | GCS artifact | `scripts/inspect_run.py:55` | Realized train/val/holdout split per region -- ground truth for any split question |

**Key artifact schemas:**

| Resource | Field | Type | Notes |
|---------|-------|------|-------|
| `split_summary.json` | `regions[].name` | string | Campaign region identifier |
| `split_summary.json` | `regions[].train_pct` | float | Realized % of pixels in train split |
| `split_summary.json` | `regions[].val_pct` | float | Realized % of pixels in val split |
| `model_metadata.json` | `model_id` | string | Unique run identifier |
| `model_metadata.json` | `config_path` | string | GCS path to the config used for this run |
| `data_quality/epoch_NNN.json` | `subgroup_metrics` | object | Per-region × per-habitat val metrics |

## 4. Pipeline Map

**Flow:**

```
gs://darwin-general-beagle/Laboratory/Data/BAP/   ← raw Best Available Pixel composites
    │
    │  src/s1_data_preparation/  (Cloud Build step 1, CPU VM)
    ▼
gs://darwin-general-beagle/Laboratory/Data/Chips/  ← normalised .pt chip tensors
    │
    ├──────────────────────────────────────────────────────────────┐
    │  model/ + split manifest  (Cloud Build step 2, GPU VM)       │  model/ + prithvi tensors (Cloud Build step 2b, GPU VM)
    ▼                                                               ▼
gs://.../Experiments/<MODEL_ID>/model_weights/      gs://.../Experiments/<MODEL_ID>/prithvi_weights/
    │                                                               │
    └───────────────────────────┬──────────────────────────────────┘
                                │  scripts/inspect_run.py  (manual, always run before any metric claim)
                                ▼
                    per-region × per-habitat metrics to stdout
                    split_summary.json  ←  ground truth for train/val split
```

**Triggers and cadence:**

| Pipeline | Trigger | Cadence |
|---------|---------|---------|
| Chip generation | Cloud Build | ad-hoc per campaign |
| UNet / LightGBM training | Cloud Build | ad-hoc per experiment |
| Prithvi fine-tuning | Cloud Build | ad-hoc per experiment |
| Evaluation | manual (`inspect_run.py`) | after every training run |

## 6. Staleness Log

| Item | Status | Last checked | Notes |
|------|--------|-------------|-------|
| `gs://darwin-general-beagle/` | current | 2026-09-21 | Root bucket confirmed active |
| `scripts/inspect_run.py` | current | 2026-09-21 | Primary ground-truth tool |
| `campaigns/` | current | 2026-09-21 | |

# ████ END OF EXAMPLE — DELETE ABOVE ████

---
---

# ARCHITECTURE -- {repo-name}

> Agentic context map. Read this before touching any file.
> Never copy from another repo -- this file maps only what lives here.
> Last reviewed: {YYYY-MM-DD} by @{who}

---

## 1. Repo Map

> DS-STD-001 · DS-STD-001-001 · DS-STD-001-002 · DS-STD-001-003
> Every path listed here is checked by `kb_staleness_audit` on every push to main.
> If a file or folder no longer exists, it gets flagged automatically.

**Purpose:** {one paragraph}

**Structure:**

| Path | Type | Purpose |
|------|------|---------|
| `.darwin/repo.json` | file | Identity manifest |
| `AGENTS.md` | file | Agentic context -- read first every session |
| `{path/}` | dir | {what lives here} |
| `{file}` | file | {what it does} |

**Entry points:**

| Entry point | Triggered by | What it does |
|-------------|-------------|--------------|
| `{file.py}` | {cron / manual / event} | {description} |

**External dependencies:**

| Dependency | Type | Declared in |
|-----------|------|-------------|
| `{name}` | {MCP / API / package} | `{file}` |

---

## 2. Database Map

> Scope: only GCP resources in THIS repo. Never include resources from other repos.
> To find them: grep for `gs://`, `bigquery`, env vars with project IDs, dataset names.
> GCS paths are flagged as `unverified` by the audit (no GitHub API access) -- verify manually with `gsutil ls`.

**GCP resources:**

| Resource | Type | Found in | Notes |
|---------|------|---------|-------|
| `{gs://bucket/path or project/dataset/table}` | {GCS / BigQuery / Firestore / CloudSQL} | `{file}:{line}` | {what it stores or does} |

**Key artifact schemas:**

| Resource | Field | Type | Notes |
|---------|-------|------|-------|
| `{file or table}` | `{field_name}` | {string / int / float / object} | {what it means} |

---

## 3. Agentic Workflow Map

> DS-STD-003 · DS-STD-003-001 · DS-STD-003-002 · DS-STD-003-003-002
> Skip this section entirely if the repo defines no agents.
> Agent definition files listed here are checked by `kb_staleness_audit` -- if a `.claude/agents/name.md` disappears, it gets flagged.

| Agent | Defined in | Tier | Trigger | Output |
|-------|-----------|------|---------|--------|
| `{agent-name}` | `{.claude/agents/name.md}` | {open/employee/admin} | {trigger} | {output} |

| Step | Agent / script | Input | Output | On failure |
|------|---------------|-------|--------|-----------|
| 1. {step} | `{file}` | {input} | {output} | {skip/retry/alert} |

| Agent | tools/ path | Key scripts |
|-------|------------|-------------|
| `{agent-name}` | `{agent-dir/tools/}` | `{script.py}` |

---

## 4. Pipeline Map

> DS-STD-003-003-001 · DS-STD-003-003-002
> Skip this section entirely if the repo runs no data or ML pipelines.
> Scripts listed in the flow are checked by `kb_staleness_audit` -- renamed or deleted scripts get flagged.

**Flow:**

```
{data source: bucket path, table, or file}
    │
    │  {script or tool}  ({trigger: Cloud Build / cron / manual})
    ▼
{intermediate output: path or resource}
    │
    │  {next script}
    ▼
{final output: path, table, or report}
```

**Triggers and cadence:**

| Pipeline | Trigger | Cadence |
|---------|---------|---------|
| `{pipeline name}` | {Cloud Build / cron / manual} | {daily / ad-hoc / on-push} |

---

## 5. Knowledge Graph Map

> DS-STD-001-002 · DS-STD-003-003-001
> Skip this section entirely if the repo has no knowledge graph.

| Node type | Defined in | Properties | Notes |
|-----------|-----------|-----------|-------|
| `{NodeType}` | `{file}` | `{fields}` | {description} |

| Edge | From | To | Defined in | Notes |
|------|------|----|-----------|-------|
| `{edge}` | `{NodeType}` | `{NodeType}` | `{file}` | {meaning} |

| Query | Used in | Purpose |
|-------|---------|---------|
| `{query}` | `{file}` | {purpose} |

---

## 6. Staleness Log

> On every push to main: checks whether pushed files are documented here.
> 5% of sessions: checks all documented paths still exist.
> Never delete a row without human confirmation.

| Item | Status | Last checked | Notes |
|------|--------|-------------|-------|
| `{path or gs:// resource}` | {current / stale} | {YYYY-MM-DD} | {notes} |
