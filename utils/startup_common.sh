#!/bin/bash
# ========================================
# SHARED STARTUP UTILITIES
# ========================================
# Source this file at the top of startup scripts to reduce duplication.
# Usage: source /path/to/startup_common.sh
#
# Provides:
#   - vm_startup_banner()    : Print startup info
#   - vm_export_metadata()   : Export VM metadata as env vars
#   - vm_setup_cleanup_trap(): Setup shutdown-on-exit trap
#   - vm_install_docker()    : Install and configure Docker
#   - vm_install_ops_agent() : Install Google Cloud Ops Agent (optional)
#   - vm_docker_auth()       : Authenticate with Artifact Registry
#   - vm_docker_pull()       : Pull Docker image with error handling
#   - vm_clean_directory()   : Clean a directory safely
#   - vm_setup_directories() : Create and chmod directories
#   - write_run_contract()   : Write JSON run contract
#   - update_run_contract()  : Update contract with final status
#   - vm_final_summary()     : Print final pipeline summary
#
# Expects these placeholders to be sed-replaced before execution:
#   __VM_NAME__, __VM_ZONE__, __CLOUDBUILD_YAML__, __BUILD_ID__,
#   __GIT_COMMIT__, __REGION__, __IMAGE_URI__, __PIPELINE_TITLE__
#
# Optional (via vm_config_{idx}.env):
#   __VM_ON_FAILURE__  — shutdown (default) | keep-alive
#   __VM_DEBUG_TTL__   — Hours to keep VM alive on failure (default: 4)
# ========================================

# Global timestamp set when script starts
VM_START_TIME="${VM_START_TIME:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

# ========================================
# vm_startup_banner
# ========================================
# Print startup banner with VM info
# Usage: vm_startup_banner
vm_startup_banner() {
  echo "=========================================="
  echo "VM STARTUP INITIATED"
  echo "=========================================="
  echo "Start Time:      ${VM_START_TIME}"
  echo "VM Name:         ${VM_NAME:-__VM_NAME__}"
  echo "VM Zone:         ${VM_ZONE:-__VM_ZONE__}"
  echo "CloudBuild YAML: ${CLOUDBUILD_YAML:-__CLOUDBUILD_YAML__}"
  echo "Build ID:        ${BUILD_ID:-__BUILD_ID__}"
  echo "Git Commit:      ${COMMIT_SHA:-__GIT_COMMIT__}"
  echo "=========================================="
}

# ========================================
# vm_export_metadata
# ========================================
# Export VM metadata as environment variables
# Usage: vm_export_metadata
vm_export_metadata() {
  export VM_NAME="${VM_NAME:-__VM_NAME__}"
  export VM_ZONE="${VM_ZONE:-__VM_ZONE__}"
  export CLOUDBUILD_YAML="${CLOUDBUILD_YAML:-__CLOUDBUILD_YAML__}"
  export BUILD_ID="${BUILD_ID:-__BUILD_ID__}"
  export COMMIT_SHA="${COMMIT_SHA:-__GIT_COMMIT__}"
  export SHORT_SHA="${SHORT_SHA:-__GIT_COMMIT__}"
}

# ========================================
# vm_setup_cleanup_trap
# ========================================
# Setup trap to shutdown VM on exit.
# Behavior on failure is controlled by VM_ON_FAILURE:
#   shutdown   (default) — VM shuts down immediately
#   keep-alive           — VM stays running for VM_DEBUG_TTL hours
# Usage: vm_setup_cleanup_trap
vm_setup_cleanup_trap() {
  _vm_cleanup() {
    local exit_code=$?
    local VM_END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "=========================================="
    echo "Start Time: ${VM_START_TIME}"
    echo "End Time  : ${VM_END_TIME}"
    echo "=========================================="

    # Success — always shutdown
    if [ "$exit_code" -eq 0 ]; then
      echo "Pipeline completed successfully — shutting down VM"
      sudo shutdown -h now
      return
    fi

    # Failure path
    local on_failure="${VM_ON_FAILURE:-shutdown}"
    local debug_ttl="${VM_DEBUG_TTL:-4}"

    echo "==========================================="
    echo "  PIPELINE FAILED (exit code: $exit_code)"
    echo "==========================================="

    if [ "$on_failure" = "keep-alive" ]; then
      echo ""
      echo "  VM_ON_FAILURE=keep-alive — VM will stay running for ${debug_ttl}h"
      echo ""
      echo "  SSH into this VM:"
      echo "    gcloud compute ssh ${VM_NAME:-unknown} --zone=${VM_ZONE:-unknown} --tunnel-through-iap"
      echo ""
      echo "  Useful debug commands:"
      echo "    docker ps -a                    # Check container status"
      echo "    docker logs \$(docker ps -aq -n1) # Last container logs"
      echo "    ls -la /tmp/                    # Check output files"
      echo "    df -h                           # Check disk space"
      echo ""
      echo "  Auto-shutdown in ${debug_ttl} hours."
      echo "  Manual shutdown: sudo shutdown -h now"
      echo "==========================================="

      # Kill the idle watchdog so it doesn't shut down the VM
      if [ -n "${WATCHDOG_PID:-}" ]; then
        kill "$WATCHDOG_PID" 2>/dev/null || true
      fi

      # Schedule delayed shutdown
      sudo shutdown -h +"$((debug_ttl * 60))" "VM debug TTL expired (${debug_ttl}h)" &

      # Keep the script alive so the trap doesn't re-fire
      sleep infinity
    else
      echo "  VM_ON_FAILURE=shutdown — shutting down now"
      sudo shutdown -h now
    fi
  }
  trap _vm_cleanup EXIT
}

# ========================================
# vm_resolve_egress_bypass
# ========================================
# Resolve the conscious cross-region egress bypass flag from its placeholder.
# Mirrors the VM_ON_FAILURE pattern: a per-VM vm_config_{idx}.env may set
# ALLOW_CROSS_REGION_EGRESS=true to consciously disable the region guard.
# Defaults to "false" (guard enforced) when the placeholder is left unreplaced.
# Usage: vm_resolve_egress_bypass
vm_resolve_egress_bypass() {
  export ALLOW_CROSS_REGION_EGRESS="${ALLOW_CROSS_REGION_EGRESS:-__ALLOW_CROSS_REGION_EGRESS__}"
  [[ "$ALLOW_CROSS_REGION_EGRESS" == "__ALLOW_CROSS_REGION_EGRESS__" ]] && ALLOW_CROSS_REGION_EGRESS="false"
  export ALLOW_CROSS_REGION_EGRESS
}

# ========================================
# vm_assert_region_bucket_match
# ========================================
# HARD region egress guard for the VM. Validates every given gs:// path / bucket
# against the VM's own region (derived from VM_ZONE). On an unbypassed mismatch
# the VM is powered off IMMEDIATELY — before any data transfer can occur.
# The ONLY way past it is to consciously set ALLOW_CROSS_REGION_EGRESS=true.
# Usage: vm_assert_region_bucket_match gs://bucket/path [gs://other ...]
vm_assert_region_bucket_match() {
  [ $# -eq 0 ] && return 0

  # Fail closed if the guard module was not bundled — never silently allow egress.
  if ! command -v region_guard_check >/dev/null 2>&1; then
    echo "[region-guard] FATAL: region_guard.sh not loaded; cannot verify bucket regions." >&2
    echo "[region-guard] Powering off VM to prevent unverified cross-region egress." >&2
    sync || true
    sudo shutdown -h now "region-egress-guard: guard module missing" 2>/dev/null \
      || sudo poweroff -f 2>/dev/null || true
    exit 1
  fi

  vm_resolve_egress_bypass

  local vm_region
  vm_region="$(region_guard_region_from_zone "${VM_ZONE:-__VM_ZONE__}")"

  if region_guard_check "$vm_region" "$@"; then
    return 0
  fi

  echo ""
  echo "[region-guard] Powering off VM NOW to prevent cross-region egress."
  sync || true
  sudo shutdown -h now "region-egress-guard: bucket/VM region mismatch" 2>/dev/null \
    || sudo poweroff -f 2>/dev/null || true
  # Belt-and-suspenders: never fall through into a transfer.
  exit 1
}

# ========================================
# vm_install_docker
# ========================================
# Install Docker and enable the service
# Usage: vm_install_docker
vm_install_docker() {
  echo ""
  echo "Installing Docker..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker.io
  sudo systemctl enable --now docker
  export PATH="/usr/bin:/usr/local/bin:$PATH"
  echo "Docker installed and enabled"
}

# ========================================
# vm_install_ops_agent
# ========================================
# Install Google Cloud Ops Agent for logging
# Usage: vm_install_ops_agent
vm_install_ops_agent() {
  echo ""
  echo "Installing Google Cloud Ops Agent..."
  curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
  sudo bash add-google-cloud-ops-agent-repo.sh --also-install 2>/dev/null || true
  echo "Ops Agent installed"
}

# ========================================
# vm_docker_auth
# ========================================
# Authenticate Docker with Artifact Registry
# Usage: vm_docker_auth "europe-west1"
vm_docker_auth() {
  local REGION="${1:-__REGION__}"
  echo ""
  echo "Authenticating Docker with Artifact Registry..."
  gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
  echo "Docker authenticated"
}

# ========================================
# vm_docker_pull
# ========================================
# Pull Docker image with error handling
# Usage: vm_docker_pull "image-uri"
# Returns: 0 on success, exits 1 on failure
vm_docker_pull() {
  local IMAGE_URI="${1:-__IMAGE_URI__}"
  echo ""
  echo "Pulling Docker image..."
  echo "Image URI: ${IMAGE_URI}"
  if /usr/bin/docker pull "${IMAGE_URI}"; then
    echo "Image pulled successfully"
    return 0
  else
    echo "ERROR: Failed to pull Docker image"
    exit 1
  fi
}

# ========================================
# vm_clean_directory
# ========================================
# Safely clean a directory if it exists
# Usage: vm_clean_directory "/tmp/my_dir"
vm_clean_directory() {
  local DIR="$1"
  if [ -d "$DIR" ]; then
    echo "  Clearing ${DIR}..."
    sudo rm -rf "${DIR:?}"/*
  fi
}

# ========================================
# vm_setup_directories
# ========================================
# Create directories and set permissions
# Usage: vm_setup_directories "/tmp/data" "/tmp/output"
vm_setup_directories() {
  for DIR in "$@"; do
    mkdir -p "$DIR"
    chmod 777 "$DIR"
  done
}

# ========================================
# vm_clean_previous_state
# ========================================
# Clean multiple directories from previous runs
# Usage: vm_clean_previous_state "/tmp/dir1" "/tmp/dir2"
vm_clean_previous_state() {
  echo ""
  echo "Cleaning previous run state..."
  for DIR in "$@"; do
    vm_clean_directory "$DIR"
  done
  echo "Previous state cleaned"
  echo ""
}

# ========================================
# vm_pipeline_header
# ========================================
# Print pipeline-specific header
# Usage: vm_pipeline_header "Feature Engineering Pipeline"
vm_pipeline_header() {
  local TITLE="${1:-__PIPELINE_TITLE__}"
  echo ""
  echo "=========================================="
  echo "${TITLE}"
  echo "=========================================="
}

# ========================================
# run_contract_cli_path
# ========================================
# Resolve run-contract CLI path if available.
run_contract_cli_path() {
  local CANDIDATES=(
    "${RUN_CONTRACT_CLI:-}"
    "/tmp/cicd_utils/run_contract.sh"
    "/workspace/cicd/utils/run_contract.sh"
    "cicd/utils/run_contract.sh"
  )
  local CANDIDATE=""
  for CANDIDATE in "${CANDIDATES[@]}"; do
    [ -z "${CANDIDATE}" ] && continue
    if [ -x "${CANDIDATE}" ]; then
      echo "${CANDIDATE}"
      return 0
    fi
  done
  return 1
}

# ========================================
# write_run_contract
# ========================================
# Write initial run contract JSON.
# IMPORTANT: All JSON arguments MUST be single-line strings.
#   Multiline heredoc JSON breaks when passed as CLI arguments.
#   Good: CONFIG_JSON="{\"key\":\"value\",\"key2\":\"value2\"}"
#   Bad:  CONFIG_JSON=$(cat <<EOF
#         { "key": "value" }
#         EOF
#         )
# Usage: write_run_contract "$CONTRACT_FILE" "$OUTPUT_GCS" "config_json" "inputs_json" "expected_outputs_json"
write_run_contract() {
  local CONTRACT_FILE="$1"
  local OUTPUT_GCS="$2"
  local CONFIG_JSON="${3:-}"
  [ -z "${CONFIG_JSON}" ] && CONFIG_JSON="{}"
  local INPUTS_JSON="${4:-}"
  local EXPECTED_OUTPUTS_JSON="${5:-}"
  local EXPECTED_INPUTS_JSON="${6:-[]}"

  echo ""
  echo "=========================================="
  echo "Writing Run Contract"
  echo "=========================================="

  # HARD region guard: the output bucket must live in the VM region too
  # (uploads incur egress just like downloads). Runs before any processing.
  if [[ "${OUTPUT_GCS}" == gs://* ]]; then
    vm_assert_region_bucket_match "${OUTPUT_GCS}"
  fi

  # Mandatory: inputs and expected_outputs must always be provided
  if [ -z "${INPUTS_JSON}" ] || [ "${INPUTS_JSON}" = "{}" ]; then
    echo "ERROR: write_run_contract requires inputs_json (arg 4). Cannot be empty." >&2
    return 1
  fi
  if [ -z "${EXPECTED_OUTPUTS_JSON}" ] || [ "${EXPECTED_OUTPUTS_JSON}" = "[]" ]; then
    echo "ERROR: write_run_contract requires expected_outputs_json (arg 5). Cannot be empty." >&2
    return 1
  fi

  local RUN_CONTRACT_CLI_PATH=""
  if ! RUN_CONTRACT_CLI_PATH="$(run_contract_cli_path)"; then
    echo "ERROR: run_contract CLI not found. Cannot write run contract." >&2
    return 1
  fi

  # Write all JSON args to temp files to avoid CLI argument passing issues
  local JSON_TMP="/tmp/run_contract_args_$$"
  mkdir -p "${JSON_TMP}"

  echo "${CONFIG_JSON}" > "${JSON_TMP}/config.json"
  echo "${INPUTS_JSON}" > "${JSON_TMP}/inputs.json"
  echo "${EXPECTED_OUTPUTS_JSON}" > "${JSON_TMP}/expected_outputs.json"

  python3 -c "
import json, sys, pathlib
tmp = pathlib.Path(sys.argv[1])
(tmp / 'run_metadata.json').write_text(json.dumps({
    'vm_name': sys.argv[2],
    'cloudbuild_yaml': sys.argv[3],
    'commit_sha': sys.argv[4],
    'build_id': sys.argv[5]
}))
" "${JSON_TMP}" "${VM_NAME:-}" "${CLOUDBUILD_YAML:-}" "${COMMIT_SHA:-}" "${BUILD_ID:-}"

  local CLI_ARGS=(
    init
    --contract-file "${CONTRACT_FILE}"
    --job-id "${PIPELINE_TITLE:-pipeline}"
    --run-id "${BUILD_ID:-}"
    --pipeline-title "${PIPELINE_TITLE:-pipeline}"
    --output-location "${OUTPUT_GCS}"
    --config-json-file "${JSON_TMP}/config.json"
    --inputs-json-file "${JSON_TMP}/inputs.json"
    --expected-assets-file "${JSON_TMP}/expected_outputs.json"
    --run-metadata-json-file "${JSON_TMP}/run_metadata.json"
  )
  if [ "${EXPECTED_INPUTS_JSON}" != "[]" ]; then
    echo "${EXPECTED_INPUTS_JSON}" > "${JSON_TMP}/expected_inputs.json"
    CLI_ARGS+=(--expected-inputs-file "${JSON_TMP}/expected_inputs.json")
  fi
  if ! "${RUN_CONTRACT_CLI_PATH}" "${CLI_ARGS[@]}"; then
    echo "ERROR: run_contract.sh init failed." >&2
    return 1
  fi

  echo "Run contract written (CLI): ${CONTRACT_FILE}"
}

# ========================================
# preflight_run_contract
# ========================================
# Verify all input assets exist before processing starts.
# Usage: preflight_run_contract "$CONTRACT_FILE" [--strict]
# Returns: CLI exit code (0=ok, 2=strict failure with missing required inputs)
preflight_run_contract() {
  local CONTRACT_FILE="$1"
  local STRICT="${2:-}"

  echo ""
  echo "=========================================="
  echo "Preflight: Checking Input Assets"
  echo "=========================================="

  local RUN_CONTRACT_CLI_PATH=""
  if ! RUN_CONTRACT_CLI_PATH="$(run_contract_cli_path)"; then
    echo "ERROR: run_contract CLI not found. Cannot run preflight check." >&2
    return 1
  fi

  local CLI_ARGS=(
    preflight
    --contract-file "${CONTRACT_FILE}"
  )
  if [ "${STRICT}" = "--strict" ]; then
    CLI_ARGS+=(--strict)
  fi
  "${RUN_CONTRACT_CLI_PATH}" "${CLI_ARGS[@]}"
  return $?
}

# ========================================
# update_run_contract
# ========================================
# Update run contract with final status
# Usage: update_run_contract "$CONTRACT_FILE" "$OUTPUT_GCS" "COMPLETE" "verification_json"
update_run_contract() {
  local CONTRACT_FILE="$1"
  local OUTPUT_GCS="$2"
  local STATUS="$3"
  local VERIFICATION_JSON="${4:-{}}"

  echo ""
  echo "Updating run contract..."

  local RUN_CONTRACT_CLI_PATH=""
  if ! RUN_CONTRACT_CLI_PATH="$(run_contract_cli_path)"; then
    echo "ERROR: run_contract CLI not found. Cannot update run contract." >&2
    return 1
  fi

  # Write verification JSON to file to avoid CLI argument passing issues
  local JSON_TMP="/tmp/run_contract_finalize_$$"
  mkdir -p "${JSON_TMP}"
  echo "${VERIFICATION_JSON}" > "${JSON_TMP}/verification.json"

  local CLI_ARGS=(
    finalize
    --contract-file "${CONTRACT_FILE}"
    --status "${STATUS}"
    --output-location "${OUTPUT_GCS}"
    --verification-json-file "${JSON_TMP}/verification.json"
  )
  # NOTE: unlike init/preflight, `finalize` has no --upload-gcs-dir flag -- it
  # already uploads the contract itself, driven by --output-location above
  # (see run_contract.py _cmd_finalize's "Upload contracts to GCS" section).
  # Passing --upload-gcs-dir here made every finalize call error with
  # "unrecognized arguments" (found 2026-08-03, erosion_lightgbm training run
  # ce10b8f3 -- the run's own failure-recording call was silently broken).
  if ! "${RUN_CONTRACT_CLI_PATH}" "${CLI_ARGS[@]}"; then
    echo "ERROR: run_contract.sh finalize failed." >&2
    return 1
  fi

  echo "Run contract updated (CLI): status=${STATUS}"
}

# ========================================
# vm_final_summary
# ========================================
# Print final pipeline summary
# Usage: vm_final_summary "COMPLETE" "Model Training" "/gs/path" "key1=value1" "key2=value2"
vm_final_summary() {
  local STATUS="$1"
  local PIPELINE_NAME="$2"
  local OUTPUT_PATH="$3"
  shift 3

  echo ""
  echo "========================================================"
  echo "              PIPELINE ${STATUS}"
  echo "========================================================"
  echo ""
  echo "Pipeline: ${PIPELINE_NAME}"

  # Print additional key=value pairs
  for KV in "$@"; do
    local KEY="${KV%%=*}"
    local VALUE="${KV#*=}"
    printf "%-12s %s\n" "${KEY}:" "${VALUE}"
  done

  echo ""
  echo "Outputs at: ${OUTPUT_PATH}"
  echo ""
  echo "VM will shutdown in 10 seconds..."
  sleep 10
}

# ========================================
# vm_start_idle_watchdog
# ========================================
# Start background watchdog that shuts down VM after inactivity
# Usage: vm_start_idle_watchdog [minutes]
# Default: 90 minutes (1.5 hours) with no Docker containers AND no gsutil/gcloud-storage transfers
vm_start_idle_watchdog() {
  local IDLE_TIMEOUT_MINUTES="${1:-90}"

  echo ""
  echo "Starting idle watchdog (${IDLE_TIMEOUT_MINUTES}min timeout)..."

  # Run watchdog in background
  (
    IDLE_COUNT=0
    while true; do
      sleep 60  # Check every minute

      # Count running Docker containers (excluding paused)
      RUNNING_CONTAINERS=$(docker ps -q 2>/dev/null | wc -l)

      # Count active GCS transfers (gsutil / gcloud storage) — pre-container data staging
      RUNNING_TRANSFERS=$(pgrep -f 'gsutil|gcloud storage' 2>/dev/null | wc -l)

      if [ "$RUNNING_CONTAINERS" -eq 0 ] && [ "$RUNNING_TRANSFERS" -eq 0 ]; then
        IDLE_COUNT=$((IDLE_COUNT + 1))
        echo "[Idle Watchdog] No containers or GCS transfers running. Idle: ${IDLE_COUNT}/${IDLE_TIMEOUT_MINUTES} min"

        if [ "$IDLE_COUNT" -ge "$IDLE_TIMEOUT_MINUTES" ]; then
          echo "[Idle Watchdog] VM idle for ${IDLE_TIMEOUT_MINUTES} minutes. Initiating shutdown..."
          echo "=========================================="
          echo "IDLE WATCHDOG: Auto-shutdown triggered"
          echo "=========================================="
          sudo shutdown -h now
          exit 0
        fi
      else
        # Reset counter if containers or GCS transfers are running
        if [ "$IDLE_COUNT" -gt 0 ]; then
          echo "[Idle Watchdog] Activity detected (containers=${RUNNING_CONTAINERS}, transfers=${RUNNING_TRANSFERS}). Resetting idle counter."
        fi
        IDLE_COUNT=0
      fi
    done
  ) &

  WATCHDOG_PID=$!
  export WATCHDOG_PID
  echo "Idle watchdog started (PID: ${WATCHDOG_PID})"
}

# ========================================
# vm_standard_init
# ========================================
# Combined initialization: banner, metadata, trap, docker, idle watchdog
# Usage: vm_standard_init [--with-ops-agent] [--idle-timeout=MINUTES]
vm_standard_init() {
  local INSTALL_OPS_AGENT=false
  local IDLE_TIMEOUT=90  # Default 90 minutes (1.5 hours)

  for arg in "$@"; do
    case $arg in
      --with-ops-agent) INSTALL_OPS_AGENT=true ;;
      --idle-timeout=*) IDLE_TIMEOUT="${arg#*=}" ;;
    esac
  done

  # Resolve VM debug mode placeholders (fall back to defaults if not set via vm_config)
  export VM_ON_FAILURE="${VM_ON_FAILURE:-__VM_ON_FAILURE__}"
  export VM_DEBUG_TTL="${VM_DEBUG_TTL:-__VM_DEBUG_TTL__}"
  [[ "$VM_ON_FAILURE" == "__VM_ON_FAILURE__" ]] && VM_ON_FAILURE="shutdown"
  [[ "$VM_DEBUG_TTL" == "__VM_DEBUG_TTL__" ]] && VM_DEBUG_TTL="4"

  # Resolve the cross-region egress bypass flag (default: guard enforced).
  vm_resolve_egress_bypass

  vm_startup_banner
  vm_export_metadata
  vm_setup_cleanup_trap
  vm_install_docker

  if [ "$INSTALL_OPS_AGENT" = true ]; then
    vm_install_ops_agent
  fi

  # Start idle watchdog (auto-shutdown after inactivity)
  vm_start_idle_watchdog "$IDLE_TIMEOUT"
}

# ========================================
# vm_download_features
# ========================================
# Download features from GCS (supports both Zarr and PT formats)
# Usage: vm_download_features GCS_PATH LOCAL_DIR FORMAT YEARS_ARRAY
#   GCS_PATH: Base GCS path (e.g., gs://bucket/Laboratory/Data/Zarr/dataset_id)
#   LOCAL_DIR: Local directory to download to
#   FORMAT: 'zarr' or 'pt'
#   YEARS_ARRAY: Space-separated years (e.g., "2021 2022 2023")
vm_download_features() {
  local GCS_PATH="$1"
  local LOCAL_DIR="$2"
  local FORMAT="$3"
  shift 3
  local YEARS_ARRAY=("$@")

  # HARD region guard: refuse to download from a bucket outside the VM region.
  vm_assert_region_bucket_match "$GCS_PATH"

  echo ""
  echo "Downloading features (${FORMAT^^} format)..."
  mkdir -p "$LOCAL_DIR"

  for YEAR in "${YEARS_ARRAY[@]}"; do
    local METADATA_FILE="${GCS_PATH}/features_${YEAR}_metadata.json"
    local LOCAL_METADATA="${LOCAL_DIR}/features_${YEAR}_metadata.json"

    if [ "$FORMAT" = "zarr" ]; then
      local ZARR_DIR="${GCS_PATH}/features_${YEAR}.zarr"
      local LOCAL_ZARR="${LOCAL_DIR}/features_${YEAR}.zarr"

      echo "  Downloading ZARR features for ${YEAR}..."
      gsutil -m cp -r "$ZARR_DIR" "$LOCAL_DIR/"

      if [ -d "$LOCAL_ZARR" ]; then
        local ZARR_SIZE=$(du -sh "$LOCAL_ZARR" | cut -f1)
        echo "    Downloaded: $LOCAL_ZARR ($ZARR_SIZE)"
      else
        echo "    ERROR: Failed to download $ZARR_DIR"
        return 1
      fi
    else
      local PT_FILE="${GCS_PATH}/features_${YEAR}.pt"
      local LOCAL_PT="${LOCAL_DIR}/features_${YEAR}.pt"

      echo "  Downloading features for ${YEAR}..."
      gsutil -m cp "$PT_FILE" "$LOCAL_PT"

      if [ -f "$LOCAL_PT" ]; then
        echo "    Downloaded: $LOCAL_PT ($(du -h "$LOCAL_PT" | cut -f1))"
      else
        echo "    ERROR: Failed to download $PT_FILE"
        return 1
      fi
    fi

    # Download metadata sidecar
    if gsutil -q stat "$METADATA_FILE" 2>/dev/null; then
      gsutil -m cp "$METADATA_FILE" "$LOCAL_METADATA"
      echo "    Downloaded: $LOCAL_METADATA"
    fi
  done

  echo "  Features download complete"
}

# ========================================
# vm_download_labels
# ========================================
# Download labels from GCS (PT format)
# Usage: vm_download_labels GCS_PATH LOCAL_DIR YEARS_ARRAY
vm_download_labels() {
  local GCS_PATH="$1"
  local LOCAL_DIR="$2"
  shift 2
  local YEARS_ARRAY=("$@")

  # HARD region guard: refuse to download from a bucket outside the VM region.
  vm_assert_region_bucket_match "$GCS_PATH"

  echo ""
  echo "Downloading labels (PT format)..."
  mkdir -p "$LOCAL_DIR"

  for YEAR in "${YEARS_ARRAY[@]}"; do
    local LABEL_FILE="${GCS_PATH}/labels_${YEAR}.pt"
    local LOCAL_LABEL="${LOCAL_DIR}/labels_${YEAR}.pt"
    local LABEL_METADATA="${GCS_PATH}/labels_${YEAR}_metadata.json"
    local LOCAL_LABEL_METADATA="${LOCAL_DIR}/labels_${YEAR}_metadata.json"

    echo "  Downloading labels for ${YEAR}..."
    gsutil -m cp "$LABEL_FILE" "$LOCAL_LABEL"

    if [ -f "$LOCAL_LABEL" ]; then
      echo "    Downloaded: $LOCAL_LABEL ($(du -h "$LOCAL_LABEL" | cut -f1))"
    else
      echo "    ERROR: Failed to download $LABEL_FILE"
      return 1
    fi

    # Download metadata sidecar
    if gsutil -q stat "$LABEL_METADATA" 2>/dev/null; then
      gsutil -m cp "$LABEL_METADATA" "$LOCAL_LABEL_METADATA"
      echo "    Downloaded: $LOCAL_LABEL_METADATA"
    fi
  done

  echo "  Labels download complete"
}
