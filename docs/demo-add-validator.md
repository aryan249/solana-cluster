# Demo: Adding a New Validator to the Solana Private Cluster

## Overview
This demo shows that adding a 4th validator requires ONLY editing the
Ansible inventory file — zero playbook modifications.

## Pre-requisites
- Cluster is running with 3 validators + 1 bootstrap + 1 RPC + 1 faucet
- A new EC2 instance is provisioned (sol-validator-4)
- SSH access is configured

---

## Step 1: Verify Current Cluster State

```bash
# SSH into bootstrap and check current validators
ssh -i ~/actions-runner/_work/solana-cluster/solana-cluster/terraform/solana-cluster-key.pem \
  -o StrictHostKeyChecking=no ubuntu@15.207.161.179

# On bootstrap:
solana gossip --url http://127.0.0.1:8899
solana validators --url http://127.0.0.1:8899
```

**Expected:** 5 nodes in gossip (bootstrap + 3 validators + RPC), 1 active validator (bootstrap)

---

## Step 2: Provision New EC2 Instance (Infrastructure)

```bash
# Update terraform.tfvars: validator_count = 4
cd terraform
terraform apply -var="validator_count=4"
# Note the new validator's public and private IP from output
```

---

## Step 3: Add Validator to Inventory (THE ONLY FILE CHANGE)

Edit `ansible/inventory/hosts.yml` — add ONE line under `[validators]`:

```yaml
        sol-validator-4:
          ansible_host: <NEW_PUBLIC_IP>
          private_ip: <NEW_PRIVATE_IP>
```

This is the ONLY change needed. No playbooks, no templates, no config files.

---

## Step 4: Run Ansible (--limit to new validator only)

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \
  --limit sol-validator-4
```

This will automatically:
1. Install common packages + Solana binary (common + solana-install roles)
2. Bootstrap role generates keypairs for validator-4 (loops over groups['validators'])
3. Creates vote account and delegates stake for validator-4
4. Validator role fetches keypairs, deploys systemd service, starts validator
5. New validator joins gossip and begins syncing

---

## Step 5: Verify New Validator Joined

```bash
# On bootstrap:
solana gossip --url http://127.0.0.1:8899
# Expected: 6 nodes now (was 5)

solana validators --url http://127.0.0.1:8899
# Expected: validator-4 identity appears

# On validator-4:
sudo systemctl status solana-validator
sudo tail -f /var/log/solana/validator.log | grep -E 'replay|gossip|vote'
```

---

## Key Points for Demo
- Only `hosts.yml` was edited — zero playbook changes
- Ansible dynamically generates keypairs for any new validator in inventory
- Vote account and stake delegation happen automatically
- systemd service is templated with correct entrypoint and genesis hash
- New validator discovers cluster via gossip and syncs from snapshot
