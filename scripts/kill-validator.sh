#!/bin/bash
set -euo pipefail
# Demonstrates Scenario 1: Kill a validator process, systemd auto-restarts it

VALIDATOR_HOST="${1:-sol-validator-1}"
RPC_URL="${2:-http://localhost:8899}"
SSH_KEY="${3:-~/.ssh/solana-cluster-key.pem}"
SSH_USER="${4:-ubuntu}"

echo "=== Scenario 1: Validator Process Kill & Auto-Recovery ==="
echo "Target: $VALIDATOR_HOST"
echo ""

# Get validator's IP from ansible inventory
VALIDATOR_IP=$(grep -A1 "$VALIDATOR_HOST" ansible/inventory/hosts.yml | grep ansible_host | awk '{print $2}' | head -1)
if [ -z "$VALIDATOR_IP" ]; then
    echo "ERROR: Could not find IP for $VALIDATOR_HOST in inventory"
    exit 1
fi
echo "Validator IP: $VALIDATOR_IP"

# Get validator identity pubkey before kill
echo "--- Pre-kill status ---"
VALIDATOR_PUBKEY=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$VALIDATOR_IP" \
    "solana-keygen pubkey /home/solana/keypairs/identity.json")
echo "Validator pubkey: $VALIDATOR_PUBKEY"
echo "Checking gossip..."
solana gossip --url "$RPC_URL" 2>/dev/null | grep "$VALIDATOR_PUBKEY" && echo "  Validator is in gossip" || echo "  Validator NOT in gossip"

# Kill the validator process with SIGKILL
echo ""
echo "--- Killing validator process (kill -9) ---"
START_TIME=$(date +%s)
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$VALIDATOR_IP" \
    "sudo pkill -9 -f solana-validator" || true
echo "Process killed at $(date)"

# Wait for systemd to restart (RestartSec=10)
echo ""
echo "--- Waiting for auto-restart (systemd RestartSec=10) ---"
sleep 5

# Poll for recovery
MAX_WAIT=120
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    if solana gossip --url "$RPC_URL" 2>/dev/null | grep -q "$VALIDATOR_PUBKEY"; then
        END_TIME=$(date +%s)
        RECOVERY_TIME=$((END_TIME - START_TIME))
        echo ""
        echo "=== RECOVERED ==="
        echo "Validator $VALIDATOR_HOST rejoined gossip in ${RECOVERY_TIME}s"
        echo ""
        echo "--- Post-recovery status ---"
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$VALIDATOR_IP" \
            "sudo systemctl status solana-validator --no-pager" 2>/dev/null | head -15
        echo ""
        solana validators --url "$RPC_URL" 2>/dev/null | head -5
        exit 0
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "  Waiting... (${ELAPSED}s elapsed)"
done

echo "ERROR: Validator did not recover within ${MAX_WAIT}s"
exit 1
