#!/bin/bash
set -euo pipefail

# -------------------------------------------------------------------
# cicd self-test runner
# Runs all test modules under cicd/tests/ to verify core utilities
# are not corrupt before any pipeline trusts them.
#
# Usage:  bash cicd/tests/run_tests.sh
# -------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

for test_script in "$SCRIPT_DIR"/test_*.py; do
    [ -f "$test_script" ] || continue
    name="$(basename "$test_script")"
    echo "--- $name ---"
    if python3 "$test_script" "$CICD_ROOT"; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
    echo ""
done

for test_script in "$SCRIPT_DIR"/test_*.sh; do
    [ -f "$test_script" ] || continue
    name="$(basename "$test_script")"
    echo "--- $name ---"
    if bash "$test_script" "$CICD_ROOT"; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
    echo ""
done

echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
    echo "SELFTEST FAILED — aborting pipeline."
    exit 1
fi

echo "SELFTEST PASSED — safe to proceed."
exit 0
