#!/bin/bash
# ========================================
# Prepare VM Startup Script
# ========================================
# Concatenates preflight + common + pipeline-specific VM script,
# then applies ALL common sed replacements.
#
# After this script, only pipeline-specific sed replacements remain.
#
# Required env vars:
#   VM_SCRIPT_NAME   - Pipeline VM script filename (e.g., 'training.sh')
#   VM_NAME          - VM instance name
#   CODE_IMAGE_NAME  - Docker image name for this pipeline
#   CLOUDBUILD_YAML  - Name of the CloudBuild YAML file
#   PIPELINE_TITLE   - Human-readable pipeline title
#   PROJECT_ID       - GCP project ID
#   SHORT_SHA        - Git commit SHA
#   BUILD_ID         - CloudBuild build ID
#   DEFAULTS_FILE    - Path to project's defaults.yaml
#
# Optional (loaded from defaults if not set):
#   _REGION, _BUCKET
#   VM_SCRIPTS_DIR   - Directory containing pipeline VM scripts
#                      (default: cloudbuild-builds/vm)
#
# Output:
#   /tmp/startup-script.sh  (ready for pipeline-specific sed additions)
# ========================================
set -euo pipefail

# Portable in-place sed: GNU accepts `-i`, BSD/macOS needs `-i ''`. Detect via
# --version (GNU supports it, BSD errors) so this script runs in CloudBuild and locally.
if sed --version >/dev/null 2>&1; then SED_INPLACE=(-i); else SED_INPLACE=(-i ''); fi

CICD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${CICD_ROOT}/config/load_defaults.sh"

VM_SCRIPT="${VM_SCRIPT_NAME:?Missing VM_SCRIPT_NAME}"
VM_SCRIPTS_DIR="${VM_SCRIPTS_DIR:-cloudbuild-builds/vm}"
VM_SCRIPT_PATH="${VM_SCRIPTS_DIR}/${VM_SCRIPT}"

if [[ ! -f "$VM_SCRIPT_PATH" ]]; then
  echo "ERROR: VM script not found: $VM_SCRIPT_PATH" >&2
  exit 1
fi

# Concatenate region guard + preflight + common + pipeline script.
# region_guard.sh first so its functions are defined before the others call them.
cat "${CICD_ROOT}/utils/region_guard.sh" \
    "${CICD_ROOT}/utils/preflight_check.sh" \
    "${CICD_ROOT}/utils/startup_common.sh" \
    > /tmp/startup-script.sh

# Embed run_contract CLI so it's available on the VM (base64-encoded)
RUN_CONTRACT_PY="${CICD_ROOT}/utils/run_contract.py"
RUN_CONTRACT_SH="${CICD_ROOT}/utils/run_contract.sh"

if [[ -f "$RUN_CONTRACT_PY" && -f "$RUN_CONTRACT_SH" ]]; then
  # GNU base64 (CloudBuild) supports -w0 for single-line; BSD/macOS base64 does not
  # and rejects a positional filename, so the local fallback reads stdin and strips
  # newlines itself (keeps the embedded blob single-line on both platforms).
  PY_B64=$(base64 -w0 "$RUN_CONTRACT_PY" 2>/dev/null || base64 < "$RUN_CONTRACT_PY" | tr -d '\n')
  SH_B64=$(base64 -w0 "$RUN_CONTRACT_SH" 2>/dev/null || base64 < "$RUN_CONTRACT_SH" | tr -d '\n')
  cat >> /tmp/startup-script.sh << EMBED_EOF

# ---- Auto-embedded run_contract CLI (extracted at VM boot) ----
_CICD_CLI_DIR="/tmp/cicd_utils"
mkdir -p "\$_CICD_CLI_DIR"
echo "${PY_B64}" | base64 -d > "\$_CICD_CLI_DIR/run_contract.py"
echo "${SH_B64}" | base64 -d > "\$_CICD_CLI_DIR/run_contract.sh"
chmod +x "\$_CICD_CLI_DIR/run_contract.sh" "\$_CICD_CLI_DIR/run_contract.py"
export RUN_CONTRACT_CLI="\$_CICD_CLI_DIR/run_contract.sh"
EMBED_EOF
  echo "Run contract CLI embedded into startup script"
else
  echo "ERROR: run_contract CLI not found at ${RUN_CONTRACT_PY} or ${RUN_CONTRACT_SH}" >&2
  exit 1
fi

# Append pipeline-specific script
cat "$VM_SCRIPT_PATH" >> /tmp/startup-script.sh
chmod +x /tmp/startup-script.sh

# Resolve values (CloudBuild substitution wins, then defaults)
REGION="${_REGION:-${CB_REGION}}"
BUCKET="${_BUCKET:-${CB_BUCKET}}"
REPOSITORY="${PROJECT_ID}-docker"
# Image-registry region is INDEPENDENT of the compute region. The Artifact Registry
# repo lives in the defaults region (CB_REGION); compute may run elsewhere — e.g.
# co-located with data in another region. Defaulting IMAGE_REGION to _REGION (as before)
# breaks the pull whenever compute is moved, since the repo only exists in CB_REGION.
# Override with _IMAGE_REGION if the repo ever moves.
IMAGE_REGION="${_IMAGE_REGION:-${CB_REGION}}"
IMAGE_URI="${IMAGE_REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${CODE_IMAGE_NAME}:${SHORT_SHA}"

# Common sed replacements (shared across ALL pipelines)
sed "${SED_INPLACE[@]}" "s|__REGION__|${REGION}|g" /tmp/startup-script.sh
sed "${SED_INPLACE[@]}" "s|__IMAGE_REGION__|${IMAGE_REGION}|g" /tmp/startup-script.sh
sed "${SED_INPLACE[@]}" "s|__IMAGE_URI__|${IMAGE_URI}|g" /tmp/startup-script.sh

# Bucket (handles both __BUCKET__ and __OUTPUT_BUCKET__ placeholders)
sed "${SED_INPLACE[@]}" "s|__BUCKET__|${BUCKET}|g" /tmp/startup-script.sh
sed "${SED_INPLACE[@]}" "s|__OUTPUT_BUCKET__|${BUCKET}|g" /tmp/startup-script.sh

# VM metadata (identical across all pipelines)
sed "${SED_INPLACE[@]}" "s|__VM_NAME__|${VM_NAME}|g" /tmp/startup-script.sh
# __VM_ZONE__ is left as-is here; create_multi_vms.sh replaces it with the actual zone
sed "${SED_INPLACE[@]}" "s|__VM_ZONE__|__VM_ZONE__|g" /tmp/startup-script.sh
sed "${SED_INPLACE[@]}" "s|__BUILD_ID__|${BUILD_ID}|g" /tmp/startup-script.sh
sed "${SED_INPLACE[@]}" "s|__GIT_COMMIT__|${SHORT_SHA}|g" /tmp/startup-script.sh
sed "${SED_INPLACE[@]}" "s|__CLOUDBUILD_YAML__|${CLOUDBUILD_YAML}|g" /tmp/startup-script.sh
sed "${SED_INPLACE[@]}" "s|__PIPELINE_TITLE__|${PIPELINE_TITLE}|g" /tmp/startup-script.sh
