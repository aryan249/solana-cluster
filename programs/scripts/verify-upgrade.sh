#!/bin/bash
set -euo pipefail

###############################################################################
# verify-upgrade.sh
#
# Verifies that a Solana program has been deployed and its upgrade authority
# is correctly configured.
#
# Usage: ./verify-upgrade.sh [RPC_URL] [PROGRAM_ID]
###############################################################################

RPC_URL="${1:-http://localhost:8899}"
PROGRAM_ID="${2:-}"
PASS=0
FAIL=0

log_pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== Program Upgrade Verification ==="
echo "RPC URL   : $RPC_URL"
echo ""

if [ -z "$PROGRAM_ID" ]; then
    echo "ERROR: PROGRAM_ID is required."
    echo "Usage: $0 [RPC_URL] <PROGRAM_ID>"
    exit 1
fi
echo "Program ID: $PROGRAM_ID"
echo ""

# Step 1: Check that the program is deployed
echo "--- Step 1: Check program is deployed ---"
PROGRAM_INFO=$(solana program show "$PROGRAM_ID" --url "$RPC_URL" 2>&1) || {
    log_fail "Program not found at $PROGRAM_ID"
    echo "$PROGRAM_INFO"
    echo ""
    echo "=== Results ==="
    echo "  Passed: $PASS"
    echo "  Failed: $FAIL"
    echo "  SOME TESTS FAILED"
    exit 1
}
echo "$PROGRAM_INFO"
echo ""
log_pass "Program is deployed"

# Step 2: Verify upgrade authority is set
echo "--- Step 2: Verify upgrade authority ---"
UPGRADE_AUTHORITY=$(echo "$PROGRAM_INFO" | grep -i "authority" | awk '{print $NF}')
if [ -n "$UPGRADE_AUTHORITY" ] && [ "$UPGRADE_AUTHORITY" != "none" ]; then
    log_pass "Upgrade authority is set: $UPGRADE_AUTHORITY"
else
    log_fail "Upgrade authority is not set or is 'none'"
fi

# Step 3: Print program data length
echo "--- Step 3: Program data length ---"
DATA_LENGTH=$(echo "$PROGRAM_INFO" | grep -i "data length" | awk '{print $(NF-1), $NF}')
if [ -n "$DATA_LENGTH" ]; then
    echo "  Data length: $DATA_LENGTH"
    log_pass "Program data length retrieved"
else
    # Try alternative field name
    DATA_LENGTH=$(echo "$PROGRAM_INFO" | grep -i "length\|size" | head -1)
    if [ -n "$DATA_LENGTH" ]; then
        echo "  $DATA_LENGTH"
        log_pass "Program data length retrieved"
    else
        log_fail "Could not determine program data length"
    fi
fi

# Step 4: Confirm the program ID has not changed
echo "--- Step 4: Confirm program ID ---"
REPORTED_ID=$(echo "$PROGRAM_INFO" | grep -i "program id\|programid" | awk '{print $NF}')
if [ -n "$REPORTED_ID" ]; then
    if [ "$REPORTED_ID" = "$PROGRAM_ID" ]; then
        log_pass "Program ID confirmed: $PROGRAM_ID"
    else
        log_fail "Program ID mismatch (expected=$PROGRAM_ID, got=$REPORTED_ID)"
    fi
else
    # If the command succeeded with the given program ID, it is implicitly confirmed
    log_pass "Program ID confirmed (queried successfully): $PROGRAM_ID"
fi

# Summary
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  ALL TESTS PASSED"; else echo "  SOME TESTS FAILED"; exit 1; fi
