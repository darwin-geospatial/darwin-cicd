# ========================================
# PREFLIGHT CHECK UTILITY (Reusable Module)
# ========================================
# Canonical module for input file validation across ALL pipelines.
# Validates that all required GCS files exist before processing.
# Fails fast with clear error messages if any inputs are missing.
#
# USAGE: CloudBuild concatenates this module with startup scripts:
#   cat preflight_check.sh startup_script.sh > /tmp/startup-script.sh
#
# No shebang here - this is prepended to scripts that have their own.
#
# CONFIGURATION (set these in startup script BEFORE calling preflight functions):
#   PREFLIGHT_GCS_BUCKET   - GCS bucket for failure reports (required for report upload)
#   PREFLIGHT_VM_NAME      - VM name for the failure report filename
#   PREFLIGHT_UTILS_PATH   - Path within bucket (default: "Laboratory/Utils/preflight_failures")
#
# API:
#   preflight_start "Title"
#     - Initialize preflight check with a descriptive title
#
#   preflight_check_file "gs://bucket/file.tif" "description"
#     - Check if a single GCS file exists
#
#   preflight_check_list "gs://a.tif,gs://b.tif" "description"
#     - Check comma-separated list of GCS files
#
#   preflight_check_year_list "$YEAR_LIST" "description" "$YEARS"
#     - Check year-keyed list (format: year:path|year:path)
#
#   preflight_check_with_delta "$YEAR_LIST" "desc" "$YEARS" "$PREV_MAP"
#     - Check year list including previous years for delta features
#
#   preflight_finalize
#     - Print summary, upload failure report if any files missing, EXIT WITH ERROR
#
# Example:
#   PREFLIGHT_GCS_BUCKET="darwin-general-beagle"
#   PREFLIGHT_VM_NAME="$VM_NAME"
#   preflight_start "Feature Engineering Inputs"
#   preflight_check_year_list "$X_LISTS" "features" "$YEARS"
#   preflight_finalize  # Uploads report to GCS if missing files, then exits
#
# ========================================

# Initialize tracking arrays
PREFLIGHT_MISSING_FILES=()
PREFLIGHT_CHECKED_COUNT=0
PREFLIGHT_START_TIME=""
# Unique GCS buckets touched during preflight (for the region egress guard)
PREFLIGHT_BUCKETS_SEEN=()

# ========================================
# Start preflight check
# ========================================
preflight_start() {
  local TITLE="${1:-Input Files}"
  PREFLIGHT_START_TIME=$(date +%s)
  PREFLIGHT_MISSING_FILES=()
  PREFLIGHT_CHECKED_COUNT=0
  PREFLIGHT_BUCKETS_SEEN=()

  echo ""
  echo "=========================================="
  echo "PREFLIGHT: Validating ${TITLE}"
  echo "=========================================="
}

# ========================================
# Check a single GCS file exists
# ========================================
preflight_check_file() {
  local FILE="$1"
  local DESC="${2:-file}"

  if [ -z "$FILE" ]; then
    return 0
  fi

  PREFLIGHT_CHECKED_COUNT=$((PREFLIGHT_CHECKED_COUNT + 1))

  # Record the bucket for the region egress guard (see preflight_finalize).
  if command -v region_guard_bucket_name >/dev/null 2>&1; then
    local _PF_BUCKET
    _PF_BUCKET="$(region_guard_bucket_name "$FILE")"
    [ -n "$_PF_BUCKET" ] && PREFLIGHT_BUCKETS_SEEN+=("$_PF_BUCKET")
  fi

  if ! gsutil -q stat "$FILE" 2>/dev/null; then
    PREFLIGHT_MISSING_FILES+=("$FILE")
    echo "  MISSING (${DESC}): $FILE"
    return 1
  fi
  return 0
}

# ========================================
# Check a comma-separated list of files
# ========================================
preflight_check_list() {
  local FILE_LIST="$1"
  local DESC="${2:-files}"

  if [ -z "$FILE_LIST" ]; then
    return 0
  fi

  IFS=',' read -ra FILES <<< "$FILE_LIST"
  for FILE in "${FILES[@]}"; do
    # Trim whitespace
    FILE=$(echo "$FILE" | xargs)
    if [ -n "$FILE" ]; then
      preflight_check_file "$FILE" "$DESC"
    fi
  done
}

# ========================================
# Check a year-keyed list (format: year:path|year:path)
# ========================================
preflight_check_year_list() {
  local YEAR_LIST="$1"
  local DESC="${2:-files}"
  local YEARS="$3"

  if [ -z "$YEAR_LIST" ] || [ -z "$YEARS" ]; then
    return 0
  fi

  for YEAR in $YEARS; do
    echo "  Checking year ${YEAR}..."

    # Extract value for this year
    local VALUE
    VALUE=$(echo "$YEAR_LIST" | tr '|' '\n' | grep "^${YEAR}:" | cut -d':' -f2- || true)

    if [ -n "$VALUE" ]; then
      # Value might be comma-separated list of files
      preflight_check_list "$VALUE" "${DESC} (${YEAR})"
    else
      echo "    WARNING: No ${DESC} defined for year ${YEAR}"
    fi
  done
}

# ========================================
# Check year-keyed list with previous years for delta features
# ========================================
preflight_check_with_delta() {
  local YEAR_LIST="$1"
  local DESC="${2:-files}"
  local YEARS="$3"
  local PREV_YEAR_MAP="$4"  # Format: "2021:2018,2023:2021"

  # Check current years
  preflight_check_year_list "$YEAR_LIST" "$DESC" "$YEARS"

  # Check previous years if delta enabled
  if [ -n "$PREV_YEAR_MAP" ]; then
    echo "  Checking previous years for delta features..."

    # Parse prev year map
    IFS=',' read -ra MAPPINGS <<< "$PREV_YEAR_MAP"
    for MAPPING in "${MAPPINGS[@]}"; do
      local CURR_YEAR=$(echo "$MAPPING" | cut -d':' -f1)
      local PREV_YEAR=$(echo "$MAPPING" | cut -d':' -f2)

      # Check if current year is in our processing list
      if echo "$YEARS" | grep -q "$CURR_YEAR"; then
        local PREV_VALUE
        PREV_VALUE=$(echo "$YEAR_LIST" | tr '|' '\n' | grep "^${PREV_YEAR}:" | cut -d':' -f2- || true)

        if [ -n "$PREV_VALUE" ]; then
          preflight_check_list "$PREV_VALUE" "${DESC} (${PREV_YEAR} for delta)"
        fi
      fi
    done
  fi
}

# ========================================
# Finalize preflight check and exit if failures
# ========================================
preflight_finalize() {
  # HARD region guard FIRST: if any input bucket is outside the VM region,
  # stop immediately to prevent cross-region egress (powers off the VM unless
  # ALLOW_CROSS_REGION_EGRESS=true). More fundamental than a missing file.
  if command -v vm_assert_region_bucket_match >/dev/null 2>&1 \
     && [ ${#PREFLIGHT_BUCKETS_SEEN[@]} -gt 0 ]; then
    vm_assert_region_bucket_match "${PREFLIGHT_BUCKETS_SEEN[@]}"
  fi

  local PREFLIGHT_END_TIME=$(date +%s)
  local PREFLIGHT_DURATION=$((PREFLIGHT_END_TIME - PREFLIGHT_START_TIME))

  echo ""
  echo "Preflight Summary:"
  echo "  Files checked: ${PREFLIGHT_CHECKED_COUNT}"
  echo "  Missing files: ${#PREFLIGHT_MISSING_FILES[@]}"
  echo "  Duration: ${PREFLIGHT_DURATION}s"

  if [ ${#PREFLIGHT_MISSING_FILES[@]} -gt 0 ]; then
    echo ""
    echo "=========================================="
    echo "ERROR: ${#PREFLIGHT_MISSING_FILES[@]} input file(s) missing!"
    echo "=========================================="
    echo "Missing files:"
    for FILE in "${PREFLIGHT_MISSING_FILES[@]}"; do
      echo "  - $FILE"
    done
    echo ""

    # Upload failure report to GCS if bucket is configured
    if [ -n "${PREFLIGHT_GCS_BUCKET:-}" ]; then
      local UTILS_PATH="${PREFLIGHT_UTILS_PATH:-Laboratory/Utils/preflight_failures}"
      local VM_ID="${PREFLIGHT_VM_NAME:-unknown_vm}"
      local TIMESTAMP=$(date -u +"%Y%m%d_%H%M%S")
      local REPORT_FILE="/tmp/preflight_fail_${VM_ID}_${TIMESTAMP}.txt"
      local GCS_PATH="gs://${PREFLIGHT_GCS_BUCKET}/${UTILS_PATH}/preflight_fail_${VM_ID}_${TIMESTAMP}.txt"

      {
        echo "=========================================="
        echo "PREFLIGHT FAILURE REPORT"
        echo "=========================================="
        echo "VM Name:       ${VM_ID}"
        echo "Timestamp:     $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
        echo "Files Checked: ${PREFLIGHT_CHECKED_COUNT}"
        echo "Files Missing: ${#PREFLIGHT_MISSING_FILES[@]}"
        echo ""
        echo "=========================================="
        echo "MISSING FILES"
        echo "=========================================="
        for FILE in "${PREFLIGHT_MISSING_FILES[@]}"; do
          echo "  - $FILE"
        done
        echo ""
        echo "=========================================="
        echo "RESOLUTION"
        echo "=========================================="
        echo "Ensure all input files exist before re-running the pipeline."
        echo "Check that upstream pipelines (feature engineering, training) completed successfully."
      } > "$REPORT_FILE"

      echo "Uploading failure report to GCS..."
      if gsutil cp "$REPORT_FILE" "$GCS_PATH" 2>/dev/null; then
        echo "  Report saved: $GCS_PATH"
      else
        echo "  WARNING: Failed to upload report (continuing with exit)"
      fi
      echo ""
    fi

    echo "Aborting to avoid wasted processing time."
    echo "Please ensure all input files exist before re-running."
    exit 1
  fi

  echo ""
  echo "All input files verified. Proceeding with processing."
  echo ""
}

# ========================================
# Check ALL years present in a year-keyed list
# ========================================
# Automatically extracts all years from the list format (year:files|year:files)
# and validates all files for each year.
preflight_check_all_years() {
  local YEAR_LIST="$1"
  local DESC="${2:-files}"

  if [ -z "$YEAR_LIST" ]; then
    echo "  WARNING: Empty year list provided"
    return 0
  fi

  # Extract all years from the list (format: year:files|year:files)
  local ALL_YEARS
  ALL_YEARS=$(echo "$YEAR_LIST" | tr '|' '\n' | cut -d':' -f1 | sort -u | tr '\n' ' ')

  echo "  Years found in list: $ALL_YEARS"

  for YEAR in $ALL_YEARS; do
    echo "  Checking year ${YEAR}..."

    # Extract value for this year
    local VALUE
    VALUE=$(echo "$YEAR_LIST" | tr '|' '\n' | grep "^${YEAR}:" | cut -d':' -f2- || true)

    if [ -n "$VALUE" ]; then
      preflight_check_list "$VALUE" "${DESC} (${YEAR})"
    else
      echo "    WARNING: No ${DESC} defined for year ${YEAR}"
    fi
  done
}

# ========================================
# Convenience function for simple use case
# ========================================
preflight_validate_files() {
  local TITLE="$1"
  shift

  preflight_start "$TITLE"

  while [ $# -gt 0 ]; do
    local FILE="$1"
    local DESC="${2:-file}"
    preflight_check_file "$FILE" "$DESC"
    shift 2 2>/dev/null || shift 1
  done

  preflight_finalize
}
