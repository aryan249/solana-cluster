# Solana Private Cluster Runbook

## Prerequisites

- **AWS Account** with permissions to create VPC, EC2, EBS, ALB, NAT Gateway, and IAM key pairs
- **Terraform** >= 1.7.0 installed locally
- **Ansible** >= 2.14 installed locally with Python 3
- **Solana CLI** >= 1.18.15 installed locally (for cluster verification)
- **AWS CLI** configured with valid credentials (`aws configure`)
- **SSH key pair** for connecting to EC2 instances
- **Git** for cloning the repository
- **curl** and **jq** for health checks
- **Go** >= 1.21 (optional, for building the stress-test CLI)
- **Docker** and **Docker Compose** installed on the bootstrap node (handled by Ansible)

## Deployment Steps

### Step 1: Clone the Repository

```bash
git clone https://github.com/your-org/solana-cluster.git
cd solana-cluster
```

### Step 2: Initialize Terraform Backend (First Time Only)

Create the S3 bucket and DynamoDB table for Terraform remote state.

```bash
cd terraform/bootstrap-backend
terraform init
terraform apply -auto-approve
cd ../..
```

**Verify:**
```bash
aws s3 ls | grep solana-cluster-tfstate
aws dynamodb list-tables | grep solana-cluster-lock
```

### Step 3: Configure Terraform Variables

Edit `terraform/terraform.tfvars` with your settings:

```bash
vi terraform/terraform.tfvars
```

At minimum, set your public IP for SSH access:
```hcl
your_ip = "YOUR_PUBLIC_IP/32"
```

**Verify:**
```bash
curl -s ifconfig.me
# Should match the IP in terraform.tfvars (without /32)
```

### Step 4: Provision Infrastructure

```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
cd ..
```

**Verify:**
```bash
cd terraform
terraform output bootstrap_public_ip
terraform output alb_dns_name
cd ..
```

### Step 5: Generate Ansible Inventory

Copy the inventory snippet from Terraform output into the Ansible hosts file:

```bash
cd terraform
terraform output -raw ansible_inventory_snippet > ../ansible/inventory/hosts.yml
cd ..
```

**Verify:**
```bash
cat ansible/inventory/hosts.yml
# Should contain real IPs, not placeholder values
```

### Step 6: Test SSH Connectivity

```bash
SSH_KEY=$(cd terraform && terraform output -raw ssh_private_key_path)
BOOTSTRAP_IP=$(cd terraform && terraform output -raw bootstrap_public_ip)
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$BOOTSTRAP_IP" "echo OK"
```

### Step 7: Run Ansible Playbook

```bash
cd ansible
ansible-playbook site.yml -i inventory/hosts.yml -v
cd ..
```

This runs in order:
1. Common packages and OS tuning on all nodes
2. Solana CLI installation on all nodes
3. Bootstrap validator genesis and startup
4. Validator configuration and startup (3 validators)
5. RPC node configuration and startup
6. Faucet startup
7. Monitoring stack deployment (Prometheus + Grafana)

**Verify:**
```bash
cd ansible
ansible all -i inventory/hosts.yml -m ping
cd ..
```

### Step 8: Verify Cluster Health

```bash
RPC_URL="http://$(cd terraform && terraform output -raw rpc_public_ip):8899"

# Check RPC health
curl -s "$RPC_URL/health"
# Expected: "ok"

# Check slot progress
solana slot --url "$RPC_URL"

# Check validators
solana validators --url "$RPC_URL"

# Check gossip peers
solana gossip --url "$RPC_URL"
```

### Step 9: Verify Monitoring

```bash
BOOTSTRAP_IP=$(cd terraform && terraform output -raw bootstrap_public_ip)

# Prometheus targets
curl -s "http://$BOOTSTRAP_IP:9090/api/v1/targets" | python3 -m json.tool | head -30

# Grafana health
curl -s "http://$BOOTSTRAP_IP:3000/api/health"
```

Access Grafana in a browser at `http://<bootstrap-ip>:3000` (default credentials: admin/admin).

### Step 10: Request Faucet Airdrop

```bash
solana airdrop 10 --url "$RPC_URL"
solana balance --url "$RPC_URL"
```

### Step 11: Deploy a Program (Optional)

```bash
# Deploy the counter program
cd programs/scripts
bash deploy-counter.sh
cd ../..

# Test SPL token operations
cd programs/scripts
bash spl-token.sh
cd ../..
```

### Step 12: Teardown

When finished, destroy all infrastructure:

```bash
cd terraform
terraform destroy -auto-approve
cd ..
```

**Verify:**
```bash
aws ec2 describe-instances --filters "Name=tag:Project,Values=solana-private-cluster" \
    --query "Reservations[].Instances[].State.Name"
# Should return empty or all "terminated"
```

## Failure Scenario Testing

### Scenario 1: Kill a Validator

```bash
bash scripts/kill-validator.sh sol-validator-1 "$RPC_URL"
```

Expected: systemd auto-restarts the validator within 30 seconds.

### Scenario 2: Add a 4th Validator

```bash
# First, launch a new EC2 instance manually or via Terraform
bash scripts/add-validator.sh <new-validator-ip> "$RPC_URL"
```

Expected: new validator joins gossip within 3 minutes.

### Scenario 3: Replace RPC Node

```bash
bash scripts/replace-rpc.sh "$RPC_URL"
```

Expected: RPC becomes healthy again within 5 minutes.

## Common Troubleshooting

### Validator not producing slots

```bash
# Check if the validator is voting
solana vote-account <VOTE_PUBKEY> --url "$RPC_URL"

# Check validator logs
ssh -i "$SSH_KEY" ubuntu@<VALIDATOR_IP> "journalctl -u solana-validator -n 100 --no-pager"

# Verify the validator has sufficient stake
solana stakes <VOTE_PUBKEY> --url "$RPC_URL"
```

### RPC node returns "behind" health status

The RPC node may fall behind the cluster during initial catchup. Wait for it to sync:

```bash
# Compare RPC slot with validator slot
solana slot --url "$RPC_URL"
solana slot --url "http://<BOOTSTRAP_IP>:8899"
```

### Ansible playbook fails on a specific host

Re-run with increased verbosity and limit to the failing host:

```bash
ansible-playbook site.yml -i inventory/hosts.yml --limit <hostname> -vvv
```

### Gossip not converging

Check that security groups allow UDP port 8001 between all nodes, and that the NAT gateway is functioning for private subnet nodes:

```bash
# From a private subnet node
ssh -i "$SSH_KEY" ubuntu@<VALIDATOR_IP> "solana gossip --entrypoint <BOOTSTRAP_PRIVATE_IP>:8001"
```

### Prometheus not scraping targets

```bash
# Check Prometheus targets page
curl -s "http://<BOOTSTRAP_IP>:9090/api/v1/targets" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(f\"{t['labels'].get('instance','?'):30s} {t['health']:10s} {t.get('lastError','')}\")
"

# Restart the monitoring stack
ssh -i "$SSH_KEY" ubuntu@<BOOTSTRAP_IP> "cd /opt/monitoring && sudo docker compose restart"
```

### Disk space running low on ledger volume

```bash
ssh -i "$SSH_KEY" ubuntu@<NODE_IP> "df -h /ledger"

# If needed, prune the ledger
ssh -i "$SSH_KEY" ubuntu@<NODE_IP> "sudo solana-ledger-tool prune --ledger /ledger --max-slots 50000"
```

### Cannot connect to ALB

```bash
# Check ALB target health
aws elbv2 describe-target-health \
    --target-group-arn $(aws elbv2 describe-target-groups \
        --query "TargetGroups[?contains(TargetGroupName,'solana')].TargetGroupArn" \
        --output text)
```
