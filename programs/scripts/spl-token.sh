#!/bin/bash
set -euo pipefail

###############################################################################
# spl-token.sh
#
# End-to-end test of SPL Token operations on a Solana cluster.
# Creates a token mint, token accounts, mints tokens, transfers, and verifies.
#
# Usage: ./spl-token.sh [RPC_URL]
###############################################################################

RPC_URL="${1:-http://localhost:8899}"
KEYPAIR_DIR="/tmp/spl-token-test"
PASS=0
FAIL=0

log_pass() { echo "  [PASS] $1"; ((PASS++)); }
log_fail() { echo "  [FAIL] $1"; ((FAIL++)); }

mkdir -p "$KEYPAIR_DIR"

echo "=== SPL Token Operations Test ==="
echo "RPC: $RPC_URL"
echo ""

# Step 1: Generate two keypairs
echo "--- Step 1: Generate keypairs ---"
solana-keygen new --outfile "$KEYPAIR_DIR/keypair1.json" --no-bip39-passphrase --force
solana-keygen new --outfile "$KEYPAIR_DIR/keypair2.json" --no-bip39-passphrase --force
PUBKEY1=$(solana-keygen pubkey "$KEYPAIR_DIR/keypair1.json")
PUBKEY2=$(solana-keygen pubkey "$KEYPAIR_DIR/keypair2.json")
echo "  Keypair 1: $PUBKEY1"
echo "  Keypair 2: $PUBKEY2"
log_pass "Keypairs generated"

# Step 2: Airdrop SOL to both
echo "--- Step 2: Airdrop SOL ---"
solana airdrop 10 "$PUBKEY1" --url "$RPC_URL" --keypair "$KEYPAIR_DIR/keypair1.json" || log_fail "Airdrop to keypair1"
solana airdrop 10 "$PUBKEY2" --url "$RPC_URL" --keypair "$KEYPAIR_DIR/keypair2.json" || log_fail "Airdrop to keypair2"
sleep 2
BAL1=$(solana balance "$PUBKEY1" --url "$RPC_URL" | awk '{print $1}')
if (( $(echo "$BAL1 > 0" | bc -l) )); then log_pass "Airdrop to keypair1 ($BAL1 SOL)"; else log_fail "Airdrop to keypair1"; fi

# Step 3: Create token mint
echo "--- Step 3: Create token mint ---"
TOKEN_MINT=$(spl-token create-token --url "$RPC_URL" --fee-payer "$KEYPAIR_DIR/keypair1.json" --mint-authority "$KEYPAIR_DIR/keypair1.json" 2>&1 | grep "Creating token" | awk '{print $3}')
if [ -n "$TOKEN_MINT" ]; then log_pass "Token mint created: $TOKEN_MINT"; else log_fail "Token mint creation"; fi

# Step 4: Create token accounts (ATAs)
echo "--- Step 4: Create token accounts ---"
ATA1=$(spl-token create-account "$TOKEN_MINT" --url "$RPC_URL" --fee-payer "$KEYPAIR_DIR/keypair1.json" --owner "$PUBKEY1" 2>&1 | grep "Creating account" | awk '{print $3}')
ATA2=$(spl-token create-account "$TOKEN_MINT" --url "$RPC_URL" --fee-payer "$KEYPAIR_DIR/keypair1.json" --owner "$PUBKEY2" 2>&1 | grep "Creating account" | awk '{print $3}')
if [ -n "$ATA1" ]; then log_pass "ATA1 created: $ATA1"; else log_fail "ATA1 creation"; fi
if [ -n "$ATA2" ]; then log_pass "ATA2 created: $ATA2"; else log_fail "ATA2 creation"; fi

# Step 5: Mint 1000 tokens to ATA1
echo "--- Step 5: Mint tokens ---"
spl-token mint "$TOKEN_MINT" 1000 "$ATA1" --url "$RPC_URL" --fee-payer "$KEYPAIR_DIR/keypair1.json" --mint-authority "$KEYPAIR_DIR/keypair1.json"
MINT_BAL=$(spl-token balance --address "$ATA1" --url "$RPC_URL" 2>&1)
if [ "$MINT_BAL" = "1000" ]; then log_pass "Minted 1000 tokens to ATA1"; else log_fail "Mint balance check (got $MINT_BAL, expected 1000)"; fi

# Step 6: Transfer 500 tokens from ATA1 to ATA2
echo "--- Step 6: Transfer tokens ---"
spl-token transfer "$TOKEN_MINT" 500 "$PUBKEY2" --url "$RPC_URL" --fee-payer "$KEYPAIR_DIR/keypair1.json" --owner "$KEYPAIR_DIR/keypair1.json" --fund-recipient
sleep 2

# Step 7: Verify balances
echo "--- Step 7: Verify balances ---"
BAL_ATA1=$(spl-token balance --address "$ATA1" --url "$RPC_URL" 2>&1)
BAL_ATA2=$(spl-token balance --address "$ATA2" --url "$RPC_URL" 2>&1)
if [ "$BAL_ATA1" = "500" ]; then log_pass "ATA1 balance = 500"; else log_fail "ATA1 balance (got $BAL_ATA1, expected 500)"; fi
if [ "$BAL_ATA2" = "500" ]; then log_pass "ATA2 balance = 500"; else log_fail "ATA2 balance (got $BAL_ATA2, expected 500)"; fi

# Step 8: Verify ATA derivation
echo "--- Step 8: Verify ATA derivation ---"
DERIVED_ATA=$(spl-token address --token "$TOKEN_MINT" --owner "$PUBKEY1" --url "$RPC_URL" 2>&1 | tail -1)
if [ "$DERIVED_ATA" = "$ATA1" ]; then log_pass "ATA derivation verified for keypair1"; else log_fail "ATA derivation (derived=$DERIVED_ATA, expected=$ATA1)"; fi

# Summary
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  ALL TESTS PASSED"; else echo "  SOME TESTS FAILED"; exit 1; fi
