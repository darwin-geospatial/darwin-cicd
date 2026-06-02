#!/bin/bash
set -uo pipefail
# -------------------------------------------------------------------
# Unit tests for utils/region_guard.sh (pure logic only — no gcloud).
# Verifies zone->region derivation, continent extraction, bucket-name
# parsing, location/region matching rules, and bypass detection.
#
# Usage: bash tests/test_region_guard.sh [CICD_ROOT]
# -------------------------------------------------------------------

CICD_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
source "${CICD_ROOT}/utils/region_guard.sh"

PASS=0
FAIL=0

# eq EXPECTED ACTUAL MESSAGE
eq() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $3 (expected '$1', got '$2')"
  fi
}

# ok_match LOCATION REGION EXPECT_RC MESSAGE   (EXPECT_RC: 0=match, 1=mismatch)
ok_match() {
  region_guard_location_ok "$1" "$2"
  local rc=$?
  if [ "$rc" -eq "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $4 (location='$1' region='$2' expected rc=$3, got rc=$rc)"
  fi
}

# --- region_guard_region_from_zone ---
eq "europe-west1"  "$(region_guard_region_from_zone europe-west1-d)"   "zone -> region (eu)"
eq "europe-north1" "$(region_guard_region_from_zone europe-north1-a)"  "zone -> region (eu-north)"
eq "us-central1"   "$(region_guard_region_from_zone us-central1-b)"    "zone -> region (us)"
eq "europe-west1"  "$(region_guard_region_from_zone europe-west1)"     "region passed through unchanged"
eq "europe-west4"  "$(region_guard_region_from_zone EUROPE-WEST4-C)"   "zone -> region (uppercase)"

# --- region_guard_continent ---
eq "europe"       "$(region_guard_continent europe-west1)"        "continent (europe)"
eq "us"           "$(region_guard_continent us-central1)"         "continent (us)"
eq "northamerica" "$(region_guard_continent northamerica-northeast1)" "continent (northamerica)"
eq "asia"         "$(region_guard_continent asia-east1)"          "continent (asia)"

# --- region_guard_bucket_name ---
eq "my-bucket" "$(region_guard_bucket_name gs://my-bucket/a/b/c)" "bucket from gs:// uri"
eq "my-bucket" "$(region_guard_bucket_name my-bucket)"            "bucket from bare name"
eq "my-bucket" "$(region_guard_bucket_name gs://my-bucket)"       "bucket from gs:// root"

# --- region_guard_location_ok (STRICT by default: only exact regional match) ---
ok_match "europe-west1"     "europe-west1"     0 "exact regional match"
ok_match "europe-west4"     "europe-southwest1" 1 "Netherlands vs Madrid -> mismatch (the real \$300 case)"
ok_match "europe-southwest1" "europe-west4"    1 "Madrid vs Netherlands -> mismatch (reverse)"
ok_match "europe-west4"     "europe-west1"     1 "different region same continent -> mismatch"
ok_match "eu"               "europe-west1"     1 "EU multi-region -> mismatch under strict default"
ok_match "eur4"             "europe-west1"     1 "EUR4 dual-region -> mismatch under strict default"
ok_match "us"               "us-central1"      1 "US multi-region -> mismatch under strict default"
ok_match ""                 "europe-west1"     1 "unknown/empty location -> fail closed"

# --- opt-in: REGION_GUARD_ALLOW_SAME_CONTINENT=true relaxes to same-continent ---
allow_match() { # LOCATION REGION EXPECT_RC MESSAGE
  local rc
  ( export REGION_GUARD_ALLOW_SAME_CONTINENT=true; region_guard_location_ok "$1" "$2" ); rc=$?
  eq "$3" "$rc" "$4"
}
allow_match "eu"          "europe-west1" 0 "[opt-in] EU multi-region matches europe VM"
allow_match "eur4"        "europe-west1" 0 "[opt-in] EUR4 dual-region matches europe VM"
allow_match "us"          "us-central1"  0 "[opt-in] US multi-region matches us VM"
allow_match "europe-west4" "europe-west1" 1 "[opt-in] still rejects different specific region"
allow_match "eu"          "us-central1"  1 "[opt-in] EU does NOT match us VM"

# --- region_guard_bypassed ---
( ALLOW_CROSS_REGION_EGRESS=true  region_guard_bypassed ); eq 0 $? "bypass true"
( ALLOW_CROSS_REGION_EGRESS=1     region_guard_bypassed ); eq 0 $? "bypass 1"
( ALLOW_CROSS_REGION_EGRESS=YES   region_guard_bypassed ); eq 0 $? "bypass YES (case-insensitive)"
( ALLOW_CROSS_REGION_EGRESS=false region_guard_bypassed ); eq 1 $? "bypass false"
( ALLOW_CROSS_REGION_EGRESS=""    region_guard_bypassed ); eq 1 $? "bypass empty"
( unset ALLOW_CROSS_REGION_EGRESS; region_guard_bypassed ); eq 1 $? "bypass unset"

echo ""
echo "region_guard: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
