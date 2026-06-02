# ========================================
# REGION EGRESS GUARD (Reusable Module)
# ========================================
# HARD RULE: a VM may only touch GCS buckets that live in the SAME location
# as the VM. Cross-region access incurs network egress billing, so a mismatch
# is treated as a fatal condition. This module is the single source of truth
# for that policy; callers decide the *stop action* for their context:
#   - Cloud Build orchestration : abort the build (exit 1) BEFORE creating a VM
#   - On the VM                 : power the VM off IMMEDIATELY (see startup_common.sh)
#
# This file performs DETECTION + BYPASS POLICY ONLY. It never shuts anything
# down itself, so it is safe to source in any context.
#
# No shebang — this is concatenated onto startup scripts that have their own.
#
# ---- Conscious bypass ----
# The guard can ONLY be disabled by explicitly setting an environment variable
# to a truthy value. There is no implicit/default bypass:
#   ALLOW_CROSS_REGION_EGRESS=true   (env / on-VM, via __ALLOW_CROSS_REGION_EGRESS__)
#   _ALLOW_CROSS_REGION_EGRESS=true  (CloudBuild substitution -> exported as above)
# When bypassed, the guard prints a loud billing warning and proceeds.
#
# ---- Fail-closed ----
# If a bucket's location cannot be determined (e.g. missing storage.buckets.get,
# transient API error), the bucket is treated as a MISMATCH. Preventing egress
# is the whole point; an unverifiable bucket is not allowed to silently leak.
# Use the bypass flag if you genuinely need to proceed.
#
# API:
#   region_guard_region_from_zone "europe-west1-d"  -> "europe-west1"
#   region_guard_continent        "europe-west1"    -> "europe"
#   region_guard_bucket_name      "gs://b/x/y"      -> "b"
#   region_guard_bucket_location  "b"               -> "europe-west1" (lowercased, "" on failure)
#   region_guard_location_ok      "<loc>" "<region>" -> 0 if no-egress, 1 if mismatch
#   region_guard_bypassed                            -> 0 if bypass enabled, 1 otherwise
#   region_guard_check "<vm_region>" gs://a gs://b...
#       Validates every bucket. Prints a report. Returns:
#         0 = all buckets match the VM region (or 0 buckets, or bypass enabled)
#         1 = at least one mismatch AND bypass NOT enabled  -> caller MUST stop
# ========================================

# Derive the GCP region from a zone: "europe-west1-d" -> "europe-west1".
# A value that is already a region (no trailing "-<letter>") is returned as-is.
region_guard_region_from_zone() {
  local zone="$1"
  zone="$(echo "$zone" | tr '[:upper:]' '[:lower:]' | xargs)"
  # Strip a trailing single-letter zone suffix if present.
  if [[ "$zone" =~ ^([a-z]+-[a-z]+[0-9]+)-[a-z]$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$zone"
  fi
}

# Continent token of a region: "europe-west1" -> "europe", "us-central1" -> "us".
region_guard_continent() {
  local region
  region="$(echo "$1" | tr '[:upper:]' '[:lower:]' | xargs)"
  echo "${region%%-*}"
}

# Extract the bucket name from a gs:// URI or bare bucket name.
#   "gs://my-bucket/a/b" -> "my-bucket" ; "my-bucket" -> "my-bucket"
region_guard_bucket_name() {
  local uri
  uri="$(echo "$1" | xargs)"
  uri="${uri#gs://}"
  echo "${uri%%/*}"
}

# Look up a bucket's location, lowercased. Echoes "" on failure (fail-closed
# is enforced by the caller treating "" as a mismatch). One retry for flakiness.
region_guard_bucket_location() {
  local bucket="$1"
  [ -z "$bucket" ] && { echo ""; return 0; }

  local loc="" attempt
  for attempt in 1 2; do
    # Preferred: modern gcloud storage.
    loc="$(gcloud storage buckets describe "gs://${bucket}" \
             --format='value(location)' 2>/dev/null || true)"
    # Fallback: legacy gsutil.
    if [ -z "$loc" ]; then
      loc="$(gsutil ls -L -b "gs://${bucket}" 2>/dev/null \
               | grep -i 'Location constraint:' \
               | head -n1 | awk -F: '{print $2}' | xargs || true)"
    fi
    [ -n "$loc" ] && break
  done

  echo "$loc" | tr '[:upper:]' '[:lower:]' | xargs
}

# Decide whether accessing a bucket in <location> from a VM in <vm_region>
# is free of cross-region egress. Returns 0 = OK (no egress), 1 = mismatch.
#
# DEFAULT = STRICT: the ONLY $0 ("same location") configuration in GCP billing is
# a regional bucket whose location string equals the VM's region exactly. Anything
# else — a different region on the same continent (e.g. europe-west4 vs
# europe-southwest1), OR a multi/dual-region bucket (EU, EUR4, …) read from a
# single region — is billed as egress and is therefore a mismatch.
#
# OPT-IN: set REGION_GUARD_ALLOW_SAME_CONTINENT=true to ALSO treat a same-continent
# multi/dual-region bucket as free. Only enable this if you have verified in your
# own billing that those reads are genuinely $0 — for most setups they are NOT.
region_guard_location_ok() {
  local location vm_region continent allow
  location="$(echo "$1" | tr '[:upper:]' '[:lower:]' | xargs)"
  vm_region="$(echo "$2" | tr '[:upper:]' '[:lower:]' | xargs)"

  # Unknown location -> fail closed.
  [ -z "$location" ] && return 1

  # Exact regional match — the only configuration GCP bills at $0.
  [ "$location" = "$vm_region" ] && return 0

  # Strict by default: anything not co-located is billable egress -> mismatch.
  allow="$(echo "${REGION_GUARD_ALLOW_SAME_CONTINENT:-}" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "$allow" in
    true|1|yes|on) ;;   # fall through to the looser same-continent rules
    *) return 1 ;;
  esac

  # ---- Opt-in only: same-continent multi/dual-region treated as free ----
  continent="$(region_guard_continent "$vm_region")"

  # A specific regional location (contains a hyphen, e.g. "europe-west4") that
  # did not match exactly is still a different region -> cross-region egress.
  [[ "$location" == *-* ]] && return 1

  # Multi-region buckets (EU / US / ASIA).
  case "$location" in
    eu)   [ "$continent" = "europe" ] && return 0 ;;
    us)   { [ "$continent" = "us" ] || [ "$continent" = "northamerica" ]; } && return 0 ;;
    asia) [ "$continent" = "asia" ] && return 0 ;;
  esac

  # Dual-region predefined codes (eur4, nam4, asia1, ...).
  case "$location" in
    eur*)  [ "$continent" = "europe" ] && return 0 ;;
    nam*)  { [ "$continent" = "us" ] || [ "$continent" = "northamerica" ]; } && return 0 ;;
    asia*) [ "$continent" = "asia" ] && return 0 ;;
  esac

  return 1
}

# Is the guard consciously bypassed? Truthy = true/1/yes/on (case-insensitive).
region_guard_bypassed() {
  local v
  v="$(echo "${ALLOW_CROSS_REGION_EGRESS:-}" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "$v" in
    true|1|yes|on) return 0 ;;
    *)             return 1 ;;
  esac
}

# Validate every bucket against the VM region.
# Usage: region_guard_check "<vm_region>" gs://a gs://b/path bare-bucket ...
# Returns 0 if all OK (or bypassed / no buckets), 1 if an unbypassed mismatch.
region_guard_check() {
  local vm_region="$1"; shift
  # Accept either a region or a zone defensively; normalize to a region.
  vm_region="$(region_guard_region_from_zone "$vm_region")"

  if [ -z "$vm_region" ]; then
    echo "[region-guard] ERROR: VM region is empty; cannot verify bucket locations." >&2
    region_guard_bypassed && { echo "[region-guard] BYPASS active — proceeding despite unknown VM region."; return 0; }
    return 1
  fi

  # Build the unique set of bucket names from the arguments.
  # Space-delimited string set (GCS bucket names never contain spaces) so this
  # stays portable to bash 3.2 (no associative arrays).
  local uniq=" " arg bucket
  for arg in "$@"; do
    [ -z "$arg" ] && continue
    bucket="$(region_guard_bucket_name "$arg")"
    [ -z "$bucket" ] && continue
    case "$uniq" in
      *" ${bucket} "*) ;;                 # already seen
      *) uniq="${uniq}${bucket} " ;;
    esac
  done

  # Nothing to check (uniq only ever holds the leading/trailing spaces).
  [ "$uniq" = " " ] && return 0

  local mismatches=() loc
  for bucket in $uniq; do
    loc="$(region_guard_bucket_location "$bucket")"
    if region_guard_location_ok "$loc" "$vm_region"; then
      echo "[region-guard] OK   ${bucket} (${loc:-?}) matches VM region ${vm_region}"
    else
      mismatches+=("${bucket} -> ${loc:-UNKNOWN}")
      echo "[region-guard] FAIL ${bucket} (${loc:-UNKNOWN}) does NOT match VM region ${vm_region}"
    fi
  done

  [ ${#mismatches[@]} -eq 0 ] && return 0

  if region_guard_bypassed; then
    echo "=========================================="
    echo "  CROSS-REGION EGRESS ALLOWED (BYPASS)"
    echo "=========================================="
    echo "  ALLOW_CROSS_REGION_EGRESS is set — proceeding DESPITE region mismatch."
    echo "  This WILL incur GCS network egress billing for:"
    local m
    for m in "${mismatches[@]}"; do echo "    - ${m}  (VM region: ${vm_region})"; done
    echo "=========================================="
    return 0
  fi

  echo "=========================================="
  echo "  REGION EGRESS GUARD — HARD STOP"
  echo "=========================================="
  echo "  VM region: ${vm_region}"
  echo "  The following bucket(s) are NOT in the VM's region:"
  local m
  for m in "${mismatches[@]}"; do echo "    - ${m}"; done
  echo ""
  echo "  Accessing these would incur cross-region GCS egress billing."
  echo "  This run is being stopped to prevent that cost."
  echo ""
  echo "  To proceed ANYWAY (you will be billed for egress), consciously set:"
  echo "    on the VM        : ALLOW_CROSS_REGION_EGRESS=true  (vm_config_{idx}.env)"
  echo "    at orchestration : _ALLOW_CROSS_REGION_EGRESS=true (CloudBuild substitution)"
  echo ""
  echo "  (A bucket shown as UNKNOWN could not be verified — missing"
  echo "   storage.buckets.get permission or a transient API error.)"
  echo "=========================================="
  return 1
}
