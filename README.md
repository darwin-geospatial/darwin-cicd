# darwin-cicd

Shared CI/CD scripts for CloudBuild VM pipelines. Consumed as a **git submodule** at `cicd/` — your project pins a specific version; CloudBuild clones it automatically via `init-submodules`.

**Get started**: [docs/SETUP.md](docs/SETUP.md) — add submodule, copy templates, configure defaults
**Create a pipeline**: [docs/STANDARD_PROJECT_TEMPLATE.md](docs/STANDARD_PROJECT_TEMPLATE.md) — full YAML + VM script template with checklist
**Run contracts**: [docs/RUN_CONTRACT_GUIDE.md](docs/RUN_CONTRACT_GUIDE.md) — expected vs actual output audit (local/VM/Cloud Run)
**Update**: `cd cicd && git pull origin main && cd .. && git add cicd && git commit -m "update cicd"`

---

## Why this exists

Every team at Darwin builds data pipelines. Without a shared framework, each team reinvents the same infrastructure: Docker builds, VM orchestration, GCS uploads, output verification, self-deleting VMs. The result is N slightly-different implementations that all do the same thing, each with its own bugs.

`darwin-cicd` solves this by splitting every pipeline into two halves:

```
┌─────────────────────────────────────────────────────────────────┐
│                      THE BIG IDEA                               │
│                                                                 │
│   Your project = WHAT to process (application logic)            │
│   darwin-cicd  = HOW to run it  (infrastructure)                │
│                                                                 │
│   ┌─────────────────────┐    ┌─────────────────────┐            │
│   │   YOUR PROJECT      │    │   cicd/ SUBMODULE    │            │
│   │                     │    │                      │            │
│   │  CloudBuild YAML    │    │  Builder scripts     │            │
│   │  Dockerfiles        │    │  VM orchestration    │            │
│   │  VM startup script  │    │  Run contracts       │            │
│   │  Job configs        │    │  Config loading      │            │
│   │  Application code   │    │  Preflight checks    │            │
│   │                     │    │                      │            │
│   │  "Process Jaen      │    │  "Build Docker,      │            │
│   │   NDVI for 2024"    │    │   create VM, track   │            │
│   │                     │    │   outputs, cleanup"   │            │
│   └─────────────────────┘    └──────────────────────┘            │
│                                                                 │
│   You change YOUR side.  cicd/ stays identical across repos.    │
└─────────────────────────────────────────────────────────────────┘
```

### What each side owns

```
YOUR PROJECT (changes per repo)          cicd/ SUBMODULE (shared, identical)
──────────────────────────────           ────────────────────────────────────
cloudbuild-builds/                       cicd/
├── config/defaults.yaml    ← project   ├── config/load_defaults.sh
├── docker/                              ├── builders/
│   ├── Dockerfile.base     ← deps      │   ├── build_base_image_step.sh
│   └── Dockerfile          ← code      │   ├── build_code_image_step.sh
└── vm/                                  │   ├── prepare_vm_startup.sh
    └── my_pipeline.sh      ← logic     │   ├── create_multi_vms.sh
                                         │   └── print_logging_link.sh
my-pipeline.yaml            ← trigger   ├── utils/
config/jobs/*.yaml          ← params    │   ├── preflight_check.sh
src/                        ← app       │   ├── startup_common.sh
                                         │   ├── run_contract.sh
                                         │   └── run_contract.py
                                         └── templates/
                                             └── (starter files you copy once)
```

### The 6-step pipeline

Every CloudBuild pipeline follows the same pattern. Steps 2-5 are identical across all repos — they just call `cicd/` scripts:

```
CloudBuild trigger fires
        │
        ▼
┌──────────────────┐
│ 0. init-submodules│  git submodule update --init
└────────┬─────────┘
         │
    ┌────▼────┐
    │         │
┌───▼──┐  ┌──▼───────────┐
│ 1.   │  │ 2. build     │
│valid-│  │ base image   │  Docker layer 1: OS + deps
│ate   │  │ (if needed)  │  Cached in Artifact Registry
└───┬──┘  └──────┬───────┘
    │            │
    │     ┌──────▼───────┐
    │     │ 3. build     │
    │     │ code layer   │  Docker layer 2: your src/
    │     │              │  Rebuilt every commit
    │     └──────┬───────┘
    │            │
    └─────┬──────┘
          │
   ┌──────▼───────┐
   │ 4. create VM │  Assembles startup script:
   │              │    preflight_check.sh
   │              │  + startup_common.sh
   │              │  + your_pipeline.sh
   │              │  → sed replaces __PLACEHOLDERS__
   │              │  → creates GCE VM
   │              │  → VM runs async, self-deletes
   └──────┬───────┘
          │
   ┌──────▼───────┐
   │ 5. summary   │  Prints build ID, output paths,
   │    report    │  Cloud Logging link
   └──────────────┘

CloudBuild exits. VM processes data independently.
```

### VM startup script assembly

The most important thing `cicd/` does is assemble the VM startup script. Your project provides the pipeline logic; `cicd/` wraps it with infrastructure:

```
prepare_vm_startup.sh concatenates:
┌──────────────────────────────┐
│ cicd/utils/preflight_check.sh│  GCS validation helpers
├──────────────────────────────┤
│ cicd/utils/startup_common.sh │  Docker auth + pull + helpers
├──────────────────────────────┤
│ YOUR vm/my_pipeline.sh       │  Your actual pipeline logic
└──────────────────────────────┘
              │
              ▼  sed replaces __PLACEHOLDERS__
     /tmp/startup-script.sh
              │
              ▼  passed to gcloud compute instances create
          GCE VM boots and runs it
```

### Config flow

Two independent config trees merge at runtime:

```
INFRASTRUCTURE CONFIG (cicd)              APPLICATION CONFIG (your project)
─────────────────────────────             ─────────────────────────────────
cloudbuild-builds/config/                 config/
  defaults.yaml                             base.yaml
    region: europe-west1                    jobs/
    bucket: my-bucket                         my_job.yaml
    service_account: ...                        name: my_job
    vm_zones: ...                               aoi_path: data/aoi/...
         │                                      variables: [ndvi, ndwi]
         ▼                                           │
  load_defaults.sh                                   ▼
    → CB_REGION, CB_BUCKET, ...              Your application reads these
    → Used by builder scripts                at runtime inside the Docker
                                             container on the VM
```

Infrastructure config tells `cicd/` WHERE to run (region, bucket, machine type). Application config tells YOUR CODE WHAT to process (AOI, dates, variables).

### How another team reuses this

```
1. git submodule add ... cicd            # Add cicd/ to your repo
2. cp cicd/templates/* your-project/     # Copy starter files
3. Edit defaults.yaml                    # Your GCP project, bucket, SA
4. Write your VM script                  # Your pipeline logic
5. Write your CloudBuild YAML            # Wire the 6 steps
6. gcloud builds submit                  # Done
```

Steps 2-5 of the CloudBuild YAML are copy-paste from the template. The only things that change between projects are:
- `defaults.yaml` (your GCP project settings)
- `vm/my_pipeline.sh` (your pipeline logic)
- CloudBuild YAML substitutions (your pipeline parameters)

---

## Must-copy templates

Templates in [templates/](templates/) to copy into your project:

| File | Copy to | Purpose |
|------|---------|---------|
| `CLAUDE.md` | Project root | AI assistant rules — keeps Claude Code following Darwin standards |
| `AGENTS.md` | Project root | AI assistant rules (AGENTS flavor) |
| `Dockerfile.base` | `cloudbuild-builds/docker/` | Base image (deps, venv, non-root user) |
| `Dockerfile` | `cloudbuild-builds/docker/` | Code layer (app source, rebuilt every commit) |
| `requirements.txt` | `cloudbuild-builds/docker/` | Python packages starter |
| `run_contract_jobs.example.json` | `cloudbuild-builds/config/run_contract_jobs.json` | Job-id based expected outputs map |

---

## What's included

```
cicd/
├── config/
│   └── load_defaults.sh           # Parses defaults.yaml → CB_* env vars
├── builders/
│   ├── build_base_image_step.sh   # Docker base image (call with bash)
│   ├── build_base_image.sh        #   └── standalone builder
│   ├── build_code_image_step.sh   # Docker code layer (call with bash)
│   ├── build_code_image.sh        #   └── standalone builder
│   ├── prepare_vm_startup.sh      # Assemble startup script + common sed (call with bash)
│   ├── create_multi_vms.sh        # Create 1..N VMs with zone fallback + logging links
│   └── print_logging_link.sh      # Print Cloud Logging URL (call with bash)
├── utils/
│   ├── region_guard.sh           # HARD region egress guard (concatenated into VM scripts)
│   ├── preflight_check.sh         # GCS validation (concatenated into VM scripts)
│   ├── startup_common.sh          # Docker auth + pull (concatenated into VM scripts)
│   ├── run_contract.sh            # Shell entrypoint for run-contract CLI
│   └── run_contract.py            # Expected-vs-actual output auditor
├── templates/
│   ├── CLAUDE.md                  # AI assistant rules template
│   ├── AGENTS.md                  # AI assistant rules template
│   ├── Dockerfile.base            # Base image template
│   ├── Dockerfile                 # Code layer template
│   ├── requirements.txt           # Common Python packages
│   └── run_contract_jobs.example.json
└── docs/
    ├── SETUP.md
    ├── STANDARD_PROJECT_TEMPLATE.md
    └── RUN_CONTRACT_GUIDE.md
```

## How defaults work

```
Your project                          cicd/ submodule
─────────────                         ────────────────
defaults.yaml ──DEFAULTS_FILE──> load_defaults.sh ──> CB_REGION, CB_BUCKET, ...
                                                           │
CloudBuild YAML ──_REGION──> builder scripts use: ${_REGION:-${CB_REGION}}
                             (CloudBuild substitution wins, then defaults)
```

Every CloudBuild step that calls `cicd/` scripts must export `DEFAULTS_FILE` pointing to your project's `defaults.yaml`.

## Region egress guard (hard rule)

To eliminate cross-region GCS egress costs, a VM may **only** access buckets that
live in the **same region** as the VM. A mismatch is fatal — the run is stopped
**before any data transfer**.

Enforced at two layers (`utils/region_guard.sh`):

| Layer | Where | Action on mismatch |
|-------|-------|--------------------|
| Orchestration (fail-fast) | `create_multi_vms.sh`, before VM creation | Aborts the build — no VM is created |
| On-VM (authoritative) | `vm_assert_region_bucket_match` — runs in `preflight_finalize`, `vm_download_features`, `vm_download_labels`, and `write_run_contract` (output bucket) | Powers the VM off **immediately** |

A bucket's region is read live via `gcloud storage buckets describe`. **Matching is
strict by default:** the only configuration GCP bills at $0 is a regional bucket whose
location string equals the VM's region *exactly* (e.g. `europe-west1` == `europe-west1`).
Everything else is a mismatch — including a different region on the same continent
(`europe-west4` vs `europe-southwest1`) and any multi-region (`EU`) or dual-region
(`EUR4`) bucket read from a single region (GCP bills those as same-continent egress).
**Fail-closed:** a bucket whose location cannot be determined (e.g. missing
`storage.buckets.get`) is also treated as a mismatch.

> Opt-in: set `REGION_GUARD_ALLOW_SAME_CONTINENT=true` to additionally treat a
> same-continent multi/dual-region bucket as free. Only enable this if you have
> confirmed in your own billing that those reads are genuinely $0.

### Conscious bypass (the only way past it)

There is no implicit override. To accept the egress cost you must explicitly set:

```
# Per-VM, on the VM (vm_config_{idx}.env):
ALLOW_CROSS_REGION_EGRESS=true

# Build-level, at orchestration (CloudBuild substitution):
_ALLOW_CROSS_REGION_EGRESS=true
```

When bypassed, the guard prints a loud billing warning and proceeds.
