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
  PY_B64=$(base64 -w0 "$RUN_CONTRACT_PY" 2>/dev/null || base64 "$RUN_CONTRACT_PY")
  SH_B64=$(base64 -w0 "$RUN_CONTRACT_SH" 2>/dev/null || base64 "$RUN_CONTRACT_SH")
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
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${CODE_IMAGE_NAME}:${SHORT_SHA}"

# Common sed replacements (shared across ALL pipelines)
sed -i "s|__REGION__|${REGION}|g" /tmp/startup-script.sh
sed -i "s|__IMAGE_URI__|${IMAGE_URI}|g" /tmp/startup-script.sh

# Bucket (handles both __BUCKET__ and __OUTPUT_BUCKET__ placeholders)
sed -i "s|__BUCKET__|${BUCKET}|g" /tmp/startup-script.sh
sed -i "s|__OUTPUT_BUCKET__|${BUCKET}|g" /tmp/startup-script.sh

# VM metadata (identical across all pipelines)
sed -i "s|__VM_NAME__|${VM_NAME}|g" /tmp/startup-script.sh
# __VM_ZONE__ is left as-is here; create_multi_vms.sh replaces it with the actual zone
sed -i "s|__VM_ZONE__|__VM_ZONE__|g" /tmp/startup-script.sh
sed -i "s|__BUILD_ID__|${BUILD_ID}|g" /tmp/startup-script.sh
sed -i "s|__GIT_COMMIT__|${SHORT_SHA}|g" /tmp/startup-script.sh
sed -i "s|__CLOUDBUILD_YAML__|${CLOUDBUILD_YAML}|g" /tmp/startup-script.sh
sed -i "s|__PIPELINE_TITLE__|${PIPELINE_TITLE}|g" /tmp/startup-script.sh
