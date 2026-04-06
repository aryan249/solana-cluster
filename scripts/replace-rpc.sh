#!/bin/bash
set -euo pipefail
# Demonstrates Scenario 3: RPC node replacement (wipe and redeploy)

RPC_URL="${1:-http://localhost:8899}"
SSH_KEY="${2:-~/.ssh/solana-cluster-key.pem}"
SSH_USER="${3:-ubuntu}"
INVENTORY_FILE="ansible/inventory/hosts.yml"

echo "=== Scenario 3: RPC Node Replacement ==="
echo ""

# Get RPC node IP from inventory
RPC_IP=$(grep -A2 "sol-rpc\|rpc-node" "$INVENTORY_FILE" | grep ansible_host | awk '{print $2}' | head -1)
if [ -z "$RPC_IP" ]; then
    echo "ERROR: Could not find RPC node IP in inventory"
    exit 1
fi
echo "RPC node IP: $RPC_IP"

# Verify current RPC health before we begin
echo ""
echo "--- Pre-replacement RPC status ---"
if curl -s "$RPC_URL/health" 2>/dev/null | grep -q "ok"; then
    echo "RPC is currently healthy"
else
    echo "WARNING: RPC is already unhealthy (proceeding anyway)"
fi

# Step 1: Stop solana-rpc service
echo ""
echo "--- Step 1: Stopping solana-rpc service ---"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$RPC_IP" \
    "sudo systemctl stop solana-rpc" 2>/dev/null || true
echo "Service stopped"

# Verify RPC is down
if curl -s --connect-timeout 5 "$RPC_URL/health" 2>/dev/null | grep -q "ok"; then
    echo "WARNING: RPC still responding, may be behind a load balancer"
else
    echo "Confirmed: RPC endpoint is down"
fi

# Step 2: Delete ledger data
echo ""
echo "--- Step 2: Deleting ledger data ---"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$RPC_IP" \
    "sudo rm -rf /ledger/*"
echo "Ledger data deleted"

# Step 3: Run Ansible to redeploy
echo ""
echo "--- Step 3: Running Ansible playbook for RPC node ---"
START_TIME=$(date +%s)

cd ansible
ansible-playbook site.yml \
    --limit sol-rpc,rpc-node \
    -i inventory/hosts.yml \
    -e "bootstrap_host=$(grep -A2 'bootstrap-validator\|sol-bootstrap' inventory/hosts.yml | grep private_ip | awk '{print $2}' | head -1)"
cd ..

# Step 4: Poll RPC health endpoint
echo ""
echo "--- Step 4: Waiting for RPC to become healthy ---"

MAX_WAIT=300
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    HEALTH=$(curl -s --connect-timeout 5 "$RPC_URL/health" 2>/dev/null || echo "unreachable")

    if echo "$HEALTH" | grep -q "ok"; then
        END_TIME=$(date +%s)
        TOTAL_TIME=$((END_TIME - START_TIME))
        echo ""
        echo "=== SUCCESS ==="
        echo "RPC node replaced and healthy in ${TOTAL_TIME}s"
        echo ""

        echo "--- Post-replacement verification ---"
        echo "Health: $HEALTH"
        echo ""

        # Check slot height
        SLOT=$(curl -s -X POST "$RPC_URL" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}' 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('result','unknown'))" 2>/dev/null || echo "unknown")
        echo "Current slot: $SLOT"

        # Check version
        VERSION=$(curl -s -X POST "$RPC_URL" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","id":1,"method":"getVersion"}' 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('solana-core','unknown'))" 2>/dev/null || echo "unknown")
        echo "Solana version: $VERSION"

        # Check identity
        IDENTITY=$(curl -s -X POST "$RPC_URL" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","id":1,"method":"getIdentity"}' 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('identity','unknown'))" 2>/dev/null || echo "unknown")
        echo "RPC identity: $IDENTITY"

        exit 0
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
    echo "  Waiting... health=$HEALTH (${ELAPSED}s elapsed)"
done

echo ""
echo "ERROR: RPC node did not become healthy within ${MAX_WAIT}s"
echo "Debug steps:"
echo "  ssh -i $SSH_KEY $SSH_USER@$RPC_IP 'journalctl -u solana-rpc -n 50 --no-pager'"
echo "  ssh -i $SSH_KEY $SSH_USER@$RPC_IP 'sudo systemctl status solana-rpc'"
exit 1
