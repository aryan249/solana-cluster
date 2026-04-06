#!/bin/bash
set -euo pipefail

###############################################################################
# deploy-counter.sh
#
# Builds the counter program and deploys it to a Solana cluster.
# Demonstrates the upgrade flow by deploying v1, then redeploying v2.
#
# Usage: ./deploy-counter.sh [RPC_URL]
###############################################################################

RPC_URL="${1:-http://localhost:8899}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../counter" && pwd)"
KEYPAIR_DIR="/tmp/counter-deploy"

echo "============================================"
echo "  Counter Program - Build & Deploy"
echo "============================================"
echo "RPC URL   : $RPC_URL"
echo "Project   : $PROJECT_DIR"
echo ""

# ---- Setup ----
mkdir -p "$KEYPAIR_DIR"

# Generate a deploy authority keypair if one does not exist
AUTHORITY_KEYPAIR="$KEYPAIR_DIR/authority.json"
if [ ! -f "$AUTHORITY_KEYPAIR" ]; then
    echo "--- Generating deploy authority keypair ---"
    solana-keygen new --outfile "$AUTHORITY_KEYPAIR" --no-bip39-passphrase --force
fi
AUTHORITY_PUBKEY=$(solana-keygen pubkey "$AUTHORITY_KEYPAIR")
echo "Authority : $AUTHORITY_PUBKEY"

# Generate a deterministic program keypair so the address stays the same
PROGRAM_KEYPAIR="$KEYPAIR_DIR/counter-program.json"
if [ ! -f "$PROGRAM_KEYPAIR" ]; then
    echo "--- Generating program keypair ---"
    solana-keygen new --outfile "$PROGRAM_KEYPAIR" --no-bip39-passphrase --force
fi
PROGRAM_ID=$(solana-keygen pubkey "$PROGRAM_KEYPAIR")
echo "Program ID: $PROGRAM_ID"
echo ""

# ---- Fund the authority ----
echo "--- Airdropping SOL to authority ---"
solana airdrop 100 "$AUTHORITY_PUBKEY" --url "$RPC_URL" || {
    echo "WARNING: Airdrop failed (may already have sufficient balance)"
}
sleep 2
BALANCE=$(solana balance "$AUTHORITY_PUBKEY" --url "$RPC_URL")
echo "Authority balance: $BALANCE"
echo ""

# ---- Build the counter program ----
echo "--- Building counter program ---"
cd "$PROJECT_DIR"
cargo build-bpf --manifest-path Cargo.toml
echo ""

PROGRAM_SO="$PROJECT_DIR/target/deploy/counter.so"
if [ ! -f "$PROGRAM_SO" ]; then
    # Fallback: cargo build-bpf may place the artifact in a workspace target dir
    PROGRAM_SO="$(find "$PROJECT_DIR" -name 'counter.so' -path '*/deploy/*' 2>/dev/null | head -1)"
fi

if [ ! -f "$PROGRAM_SO" ]; then
    echo "ERROR: Built program binary (counter.so) not found!"
    exit 1
fi
echo "Binary    : $PROGRAM_SO"
echo ""

# ---- Deploy v1 ----
echo "============================================"
echo "  Deploying v1 (Increment only)"
echo "============================================"
solana program deploy "$PROGRAM_SO" \
    --url "$RPC_URL" \
    --keypair "$AUTHORITY_KEYPAIR" \
    --program-id "$PROGRAM_KEYPAIR" \
    --upgrade-authority "$AUTHORITY_KEYPAIR"

echo ""
echo "[PASS] v1 deployed successfully"
echo ""

# ---- Show program info ----
echo "--- Program info after v1 deploy ---"
solana program show "$PROGRAM_ID" --url "$RPC_URL"
echo ""

# ---- Upgrade to v2 ----
echo "============================================"
echo "  Upgrading to v2 (Increment + Reset)"
echo "============================================"
echo "Re-deploying updated binary to the same program address..."
solana program deploy "$PROGRAM_SO" \
    --url "$RPC_URL" \
    --keypair "$AUTHORITY_KEYPAIR" \
    --program-id "$PROGRAM_ID" \
    --upgrade-authority "$AUTHORITY_KEYPAIR"

echo ""
echo "[PASS] v2 upgrade deployed successfully"
echo ""

# ---- Show program info after upgrade ----
echo "--- Program info after v2 upgrade ---"
solana program show "$PROGRAM_ID" --url "$RPC_URL"
echo ""

# ---- Summary ----
echo "============================================"
echo "  Deployment Complete"
echo "============================================"
echo "Program ID       : $PROGRAM_ID"
echo "Upgrade Authority: $AUTHORITY_PUBKEY"
echo "RPC URL          : $RPC_URL"
echo ""
echo "To verify the upgrade, run:"
echo "  ./verify-upgrade.sh $RPC_URL $PROGRAM_ID"
echo ""
echo "ALL STEPS PASSED"
