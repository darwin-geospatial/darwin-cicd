#!/bin/bash
set -euo pipefail
# ========================================
# Universal VM Orchestrator
# ========================================
# Creates 1..N VMs from workspace config files.
# Single entry point for ALL pipelines.
#
# Reads:
#   /workspace/vm_count.txt           - Number of VMs to create
#   /workspace/vm_config_{idx}.env    - KEY=VALUE pairs per VM (idx starts at 1)
#   /workspace/vm_labels_{idx}.txt    - GCP instance labels per VM (optional)
#
# Each KEY=VALUE in vm_config becomes: sed "s|__KEY__|VALUE|g" on startup script.
# Values containing '|' automatically use '#' as sed delimiter.
#
# Special config keys:
#   AREA or VM_SUFFIX  - Used for VM naming and {AREA} placeholder in PIPELINE_TITLE
#
# Required env vars (shared across all VMs):
#   VM_SCRIPT_NAME   - Pipeline VM script filename (e.g., 'training.sh')
#   CODE_IMAGE_NAME  - Docker image name for this pipeline
#   CLOUDBUILD_YAML  - Name of the CloudBuild YAML file
#   PIPELINE_TITLE   - Human-readable title ({AREA} placeholder supported)
#   PROJECT_ID       - GCP project ID
#   SHORT_SHA        - Git commit SHA
#   BUILD_ID         - CloudBuild build ID
#   DEFAULTS_FILE    - Path to project's defaults.yaml
#   _REGION, _BUCKET
#   _MACHINE_TYPE, _BOOT_DISK_SIZE, _VM_SERVICE_ACCOUNT, _USE_SPOT
#   MAX_RUN_DURATION
# ========================================

# Portable in-place sed: GNU accepts `-i`, BSD/macOS needs `-i ''`. Detect via
# --version (GNU supports it, BSD errors) so this script runs in CloudBuild and locally.
if sed --version >/dev/null 2>&1; then SED_INPLACE=(-i); else SED_INPLACE=(-i ''); fi

CICD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load defaults
source "${CICD_ROOT}/config/load_defaults.sh"

# Workspace dir holding the vm_*.env/txt config files. Defaults to /workspace (the
# CloudBuild mount) but is overridable so the orchestrator can run outside CloudBuild
# (e.g. locally) — set WORKSPACE_DIR to any writable directory.
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
VM_COUNT_FILE="${WORKSPACE_DIR}/vm_count.txt"
if [[ ! -f "$VM_COUNT_FILE" ]]; then
  echo "ERROR: $VM_COUNT_FILE not found" >&2
  exit 1
fi
VM_COUNT=$(cat "$VM_COUNT_FILE")

if [[ "$VM_COUNT" -lt 1 ]]; then
  echo "ERROR: vm_count must be >= 1, got $VM_COUNT" >&2
  exit 1
fi

echo ""
echo "=========================================="
echo "Universal VM Orchestrator: $VM_COUNT VM(s)"
echo "=========================================="
echo ""

# Resolve shared VM defaults
TRAINING_ZONES="${TRAINING_ZONES:-${CB_VM_ZONES}}"
_MACHINE_TYPE="${_MACHINE_TYPE:?Missing _MACHINE_TYPE}"
_GPU_TYPE="${_GPU_TYPE:-}"
_GPU_COUNT="${_GPU_COUNT:-0}"
_BOOT_DISK_SIZE="${_BOOT_DISK_SIZE:-${CB_BOOT_DISK_SIZE}}"
_VM_SERVICE_ACCOUNT="${_VM_SERVICE_ACCOUNT:-${CB_VM_SERVICE_ACCOUNT}}"
USE_SPOT=$(echo "${_USE_SPOT:-false}" | tr '[:upper:]' '[:lower:]')
MAX_RUN_DURATION="${MAX_RUN_DURATION:-5h}"

# Parse zone list
IFS=',' read -ra ZONES <<< "$TRAINING_ZONES"
if [[ ${#ZONES[@]} -eq 0 ]]; then
  echo "ERROR: No zones configured" >&2
  exit 1
fi

# Enforce EU-only zones
for _Z in "${ZONES[@]}"; do
  _Z_TRIMMED="$(echo "$_Z" | xargs)"
  if [[ -n "$_Z_TRIMMED" && ! "$_Z_TRIMMED" =~ ^europe- ]]; then
    echo "ERROR: Non-EU zone rejected: $_Z_TRIMMED (only europe-* zones allowed)" >&2
    exit 1
  fi
done

# Enforce EU-only region
if [[ -n "${_REGION:-}" && ! "$_REGION" =~ ^europe- ]]; then
  echo "ERROR: Non-EU region rejected: $_REGION (only europe-* regions allowed)" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# HARD region egress guard (orchestration-time fail-fast)
# ----------------------------------------------------------------------
# Refuse to even create a VM if the output bucket lives outside the target
# region — cross-region access incurs GCS egress billing. The on-VM guard
# (vm_assert_region_bucket_match) is the authoritative runtime backstop that
# checks the VM's ACTUAL zone; this orchestration check just fails fast so we
# don't pay for VM startup on an obvious mismatch.
# Bypass ONLY by consciously setting _ALLOW_CROSS_REGION_EGRESS=true.
source "${CICD_ROOT}/utils/region_guard.sh"
export ALLOW_CROSS_REGION_EGRESS="${_ALLOW_CROSS_REGION_EGRESS:-false}"
GUARD_REGION="${_REGION:-${CB_REGION:-}}"
if [[ -z "$GUARD_REGION" ]]; then
  GUARD_REGION="$(region_guard_region_from_zone "$(echo "${ZONES[0]}" | xargs)")"
fi
GUARD_BUCKET="${_BUCKET:-${CB_BUCKET:-}}"
if [[ -n "$GUARD_BUCKET" ]]; then
  echo ""
  echo "Region egress guard (orchestration): region=${GUARD_REGION} bucket=${GUARD_BUCKET}"
  if ! region_guard_check "$GUARD_REGION" "$GUARD_BUCKET"; then
    echo "ERROR: Region egress guard blocked VM creation (bucket/region mismatch)." >&2
    exit 1
  fi
fi

# VM image settings
GPU_IMAGE_FAMILY="${GPU_IMAGE_FAMILY:-pytorch-2-9-cu129-ubuntu-2204-nvidia-580}"
GPU_IMAGE_PROJECT="${GPU_IMAGE_PROJECT:-deeplearning-platform-release}"
BOOT_DISK_TYPE="${BOOT_DISK_TYPE:-pd-standard}"
INSTANCE_METADATA="${INSTANCE_METADATA:-google-logging-enabled=true,google-monitoring-enabled=true,install-nvidia-driver=True,startup-script-running=TRUE}"

# Save original PIPELINE_TITLE for per-VM {AREA} resolution
ORIG_PIPELINE_TITLE="${PIPELINE_TITLE}"
ALL_VM_NAMES=""

for IDX in $(seq 1 "$VM_COUNT"); do
  CONFIG_FILE="${WORKSPACE_DIR}/vm_config_${IDX}.env"
  LABELS_FILE="${WORKSPACE_DIR}/vm_labels_${IDX}.txt"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    exit 1
  fi

  # Extract VM suffix (AREA or VM_SUFFIX from config)
  VM_SUFFIX=""
  while IFS= read -r LINE; do
    [[ -z "$LINE" || "$LINE" =~ ^# || "$LINE" != *"="* ]] && continue
    KEY="${LINE%%=*}"
    VALUE="${LINE#*=}"
    if [[ "$KEY" == "AREA" || "$KEY" == "VM_SUFFIX" ]]; then
      VM_SUFFIX="$VALUE"
      break
    fi
  done < "$CONFIG_FILE"
  VM_SUFFIX="${VM_SUFFIX:-vm${IDX}}"

  # Read instance labels
  if [[ -f "$LABELS_FILE" ]]; then
    INSTANCE_LABELS=$(cat "$LABELS_FILE")
  else
    INSTANCE_LABELS="type=vm,build=${SHORT_SHA:-unknown}"
  fi

  # Build VM name from CODE_IMAGE_NAME + suffix + timestamp
  VM_PREFIX=$(echo "$CODE_IMAGE_NAME" | tr '_' '-')
  export VM_NAME="${VM_PREFIX}-${VM_SUFFIX}-$(date +%Y%m%d-%H%M%S)"

  # Resolve {AREA} placeholder in title
  export PIPELINE_TITLE="${ORIG_PIPELINE_TITLE//\{AREA\}/$VM_SUFFIX}"

  echo "--- VM $IDX/$VM_COUNT: $VM_NAME ---"

  # 1. Prepare startup script (concatenate + common seds)
  bash "${CICD_ROOT}/builders/prepare_vm_startup.sh"

  # 2. Copy to per-VM path to avoid overwriting in multi-VM loops
  STARTUP_FILE="/tmp/startup-script-${VM_SUFFIX}.sh"
  cp /tmp/startup-script.sh "$STARTUP_FILE"

  # 3. Apply per-VM config as sed replacements
  while IFS= read -r LINE; do
    [[ -z "$LINE" || "$LINE" =~ ^# || "$LINE" != *"="* ]] && continue
    KEY="${LINE%%=*}"
    VALUE="${LINE#*=}"
    if [[ "$VALUE" == *"|"* ]]; then
      sed "${SED_INPLACE[@]}" "s#__${KEY}__#${VALUE}#g" "$STARTUP_FILE"
    else
      sed "${SED_INPLACE[@]}" "s|__${KEY}__|${VALUE}|g" "$STARTUP_FILE"
    fi
  done < "$CONFIG_FILE"

  # 4. Cleanup old VMs with same prefix
  VM_NAME_PREFIX=$(echo "$VM_NAME" | sed -E 's/-[0-9]{8}-[0-9]{6}$//')
  for RAW_ZONE in "${ZONES[@]}"; do
    ZONE="$(echo "$RAW_ZONE" | xargs)"
    [[ -z "$ZONE" ]] && continue
    MATCHING_VMS=$(gcloud compute instances list \
      --zones="$ZONE" \
      --filter="name:${VM_NAME_PREFIX}*" \
      --format="value(name,status)" 2>/dev/null || echo "")
    if [[ -n "$MATCHING_VMS" ]]; then
      while IFS= read -r VM_LINE; do
        OLD_VM_NAME=$(echo "$VM_LINE" | awk '{print $1}')
        OLD_VM_STATUS=$(echo "$VM_LINE" | awk '{print $2}')
        [[ -z "$OLD_VM_NAME" ]] && continue
        case "$OLD_VM_STATUS" in
          RUNNING)
            echo "  Skipping running VM: ${OLD_VM_NAME} in ${ZONE}"
            ;;
          SUSPENDED|TERMINATED|STOPPING|SUSPENDING|STAGING)
            echo "  Cleaning up stopped VM: ${OLD_VM_NAME} in ${ZONE}"
            gcloud compute instances delete "$OLD_VM_NAME" --zone="$ZONE" --quiet || true
            ;;
        esac
      done <<< "$MATCHING_VMS"
    fi
  done

  # 5. Create VM with zone fallback
  VM_CREATED=false
  ACTUAL_ZONE=""
  for RAW_ZONE in "${ZONES[@]}"; do
    ZONE="$(echo "$RAW_ZONE" | xargs)"
    [[ -z "$ZONE" ]] && continue
    echo "Trying zone: $ZONE..."

    # Replace zone placeholder in startup script
    sed "s|__VM_ZONE__|$ZONE|g" "$STARTUP_FILE" > "/tmp/startup-script-${ZONE}.sh"
    ZONE_STARTUP="/tmp/startup-script-${ZONE}.sh"

    # TODO(egress): the region guard only catches LOCATION mismatches. It cannot
    # catch *same-region* egress caused by the network path — a VM reaching GCS over
    # its external IP / public storage.googleapis.com instead of via Private Google
    # Access is billed as internet egress even when the bucket is in the same region.
    # Follow-up: create VMs with --no-address on a subnet that has Private Google
    # Access enabled (and verify routing) so same-region reads stay internal/free.
    CREATE_CMD=(gcloud compute instances create "$VM_NAME"
      --zone="$ZONE"
      --machine-type="$_MACHINE_TYPE"
      --boot-disk-size="$_BOOT_DISK_SIZE"
      --boot-disk-type="$BOOT_DISK_TYPE"
      --max-run-duration="$MAX_RUN_DURATION"
      --instance-termination-action=DELETE
      --service-account="$_VM_SERVICE_ACCOUNT"
      --scopes=cloud-platform
      --metadata-from-file="startup-script=$ZONE_STARTUP"
      --metadata="$INSTANCE_METADATA"
      --labels="$INSTANCE_LABELS"
    )

    # Add GPU-specific flags only if GPU is requested
    if [[ -n "$_GPU_TYPE" && "$_GPU_COUNT" -gt 0 ]]; then
      CREATE_CMD+=(
        --accelerator="type=$_GPU_TYPE,count=$_GPU_COUNT"
        --image-family="$GPU_IMAGE_FAMILY"
        --image-project="$GPU_IMAGE_PROJECT"
        --maintenance-policy=TERMINATE
      )
    else
      CREATE_CMD+=(
        --image-family="${CPU_IMAGE_FAMILY:-ubuntu-2204-lts}"
        --image-project="${CPU_IMAGE_PROJECT:-ubuntu-os-cloud}"
      )
    fi

    if [[ "$USE_SPOT" == "true" ]]; then
      CREATE_CMD+=("--provisioning-model=SPOT" "--instance-termination-action=DELETE")
    fi

    if [[ -n "${RESERVATION_NAME:-}" ]]; then
      CREATE_CMD+=(
        --reservation="$RESERVATION_NAME"
        --reservation-affinity=specific
      )
    fi

    if "${CREATE_CMD[@]}" 2>&1; then
      VM_CREATED=true
      ACTUAL_ZONE="$ZONE"
      break
    else
      echo "Zone $ZONE unavailable, trying next..."
    fi
  done

  if [[ "$VM_CREATED" != "true" ]]; then
    echo "ERROR: Could not create VM $VM_NAME in any configured zone" >&2
    exit 1
  fi

  echo "$ACTUAL_ZONE" > "${WORKSPACE_DIR}/vm_zone_${IDX}.txt"

  # Capture creation timestamp for absolute time range in logging URLs
  VM_CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  VM_LOGS_END=$(date -u -d "+7 days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -v+7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || echo "")
  echo "$VM_CREATED_AT" > "${WORKSPACE_DIR}/vm_created_at_${IDX}.txt"

  # Get instance ID for Cloud Logging
  INSTANCE_ID=$(gcloud compute instances describe "$VM_NAME" --zone="$ACTUAL_ZONE" --format='get(id)' 2>/dev/null || echo "")
  echo "$INSTANCE_ID" > "${WORKSPACE_DIR}/vm_instance_id_${IDX}.txt"
  echo "$VM_NAME" > "${WORKSPACE_DIR}/vm_name_${IDX}.txt"

  echo "VM created in zone: $ACTUAL_ZONE"

  # Cloud Logging link (absolute time range so it works days later)
  PROJECT_ID_FOR_URL="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
  if [[ -n "$INSTANCE_ID" ]]; then
    LOGS_QUERY="resource.type%3D%22gce_instance%22%20resource.labels.zone%3D%22${ACTUAL_ZONE}%22%20resource.labels.instance_id%3D%22${INSTANCE_ID}%22%20severity%3E%3DDEFAULT"
  else
    LOGS_QUERY="resource.type%3D%22gce_instance%22%20%22${VM_NAME}%22%20severity%3E%3DDEFAULT"
  fi
  TIME_RANGE=""
  if [[ -n "$VM_LOGS_END" ]]; then
    TIME_RANGE=";timeRange=${VM_CREATED_AT}%2F${VM_LOGS_END}"
  fi
  echo "Logs: https://console.cloud.google.com/logs/query;query=${LOGS_QUERY}${TIME_RANGE};project=${PROJECT_ID_FOR_URL}"

  # Collect VM names
  ALL_VM_NAMES="${ALL_VM_NAMES:+${ALL_VM_NAMES} }${VM_NAME}"
  echo ""
done

# Save all VM names
echo "$ALL_VM_NAMES" > "${WORKSPACE_DIR}/vm_names.txt"

echo "=========================================="
echo "All $VM_COUNT VM(s) created successfully"
echo "=========================================="
