#!/bin/bash
set -euo pipefail
# Demonstrates Scenario 2: Add a 4th validator via inventory-only scaling

NEW_VALIDATOR_IP="${1:-}"
RPC_URL="${2:-http://localhost:8899}"
SSH_KEY="${3:-~/.ssh/solana-cluster-key.pem}"
SSH_USER="${4:-ubuntu}"
INVENTORY_FILE="ansible/inventory/hosts.yml"

echo "=== Scenario 2: Add 4th Validator (Inventory-Only Scaling) ==="
echo ""

if [ -z "$NEW_VALIDATOR_IP" ]; then
    echo "Usage: $0 <new-validator-public-ip> [rpc-url] [ssh-key] [ssh-user]"
    echo ""
    echo "Prerequisites:"
    echo "  1. Launch a new EC2 instance (t3.medium, Ubuntu 22.04)"
    echo "  2. Attach it to the validators security group"
    echo "  3. Place it in the private subnet (10.0.2.0/24)"
    echo "  4. Ensure the SSH key is authorized on the instance"
    echo ""
    echo "Example:"
    echo "  $0 54.123.45.67"
    exit 1
fi

echo "New validator IP: $NEW_VALIDATOR_IP"
echo ""

# Verify SSH connectivity before proceeding
echo "--- Verifying SSH connectivity ---"
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$NEW_VALIDATOR_IP" "echo OK" >/dev/null 2>&1; then
    echo "ERROR: Cannot SSH to $NEW_VALIDATOR_IP"
    echo "  Ensure the instance is running and SSH key is correct"
    exit 1
fi
echo "SSH connectivity confirmed"
echo ""

# Check if sol-validator-4 already exists in inventory
if grep -q "sol-validator-4" "$INVENTORY_FILE" 2>/dev/null; then
    echo "WARNING: sol-validator-4 already exists in inventory. Updating IP..."
    sed -i.bak "s/ansible_host: .*/ansible_host: $NEW_VALIDATOR_IP/" "$INVENTORY_FILE"
else
    echo "--- Adding sol-validator-4 to inventory ---"
    # Get the private IP of the new instance
    PRIVATE_IP=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$NEW_VALIDATOR_IP" \
        "hostname -I | awk '{print \$1}'" 2>/dev/null)
    echo "Detected private IP: $PRIVATE_IP"

    # Insert sol-validator-4 after the last validator entry in the inventory
    # Find the line with validator-3's private_ip and append after it
    sed -i.bak "/validator-3/,/private_ip/ {
        /private_ip/ a\\
\\        sol-validator-4:\\
\\          ansible_host: $NEW_VALIDATOR_IP\\
\\          private_ip: $PRIVATE_IP
    }" "$INVENTORY_FILE"

    echo "Inventory updated. New entry:"
    grep -A2 "sol-validator-4" "$INVENTORY_FILE"
fi
echo ""

# Run ansible-playbook limited to the new validator
echo "--- Running Ansible playbook for sol-validator-4 ---"
START_TIME=$(date +%s)

cd ansible
ansible-playbook site.yml \
    --limit sol-validator-4 \
    -i inventory/hosts.yml \
    -e "bootstrap_host=$(grep -A2 'bootstrap-validator\|sol-bootstrap' inventory/hosts.yml | grep private_ip | awk '{print $2}' | head -1)"
cd ..

echo ""
echo "--- Waiting for validator to join gossip ---"

MAX_WAIT=180
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    GOSSIP_COUNT=$(solana gossip --url "$RPC_URL" 2>/dev/null | wc -l)
    echo "  Gossip nodes: $GOSSIP_COUNT (${ELAPSED}s elapsed)"

    # Check if the new validator's IP appears in gossip
    if solana gossip --url "$RPC_URL" 2>/dev/null | grep -q "$NEW_VALIDATOR_IP"; then
        END_TIME=$(date +%s)
        TOTAL_TIME=$((END_TIME - START_TIME))
        echo ""
        echo "=== SUCCESS ==="
        echo "sol-validator-4 ($NEW_VALIDATOR_IP) joined the cluster in ${TOTAL_TIME}s"
        echo ""
        echo "--- Cluster status ---"
        solana validators --url "$RPC_URL" 2>/dev/null
        echo ""
        echo "--- Gossip peers ---"
        solana gossip --url "$RPC_URL" 2>/dev/null
        exit 0
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

echo ""
echo "ERROR: sol-validator-4 did not appear in gossip within ${MAX_WAIT}s"
echo "Debug: check 'journalctl -u solana-validator' on the new node"
exit 1
