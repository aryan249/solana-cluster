# Failure Scenario Test Results

## Scenario 1: Validator Process Kill & Auto-Recovery

### Description
Simulate a validator crash by sending SIGKILL to the solana-validator process. Verify that systemd automatically restarts the process and the validator rejoins the cluster.

### Command Used
```bash
bash scripts/kill-validator.sh sol-validator-1 http://<RPC_IP>:8899
```

### Pre-Kill State
- Validator identity pubkey: FILL IN AFTER TESTING
- Gossip peers before kill: FILL IN AFTER TESTING
- Active validators: FILL IN AFTER TESTING
- Current slot at time of kill: FILL IN AFTER TESTING

### Journal Logs Observed
```
FILL IN AFTER TESTING

Paste relevant output from:
  ssh ubuntu@<VALIDATOR_IP> "journalctl -u solana-validator -n 50 --no-pager"

Look for:
  - Process termination signal
  - systemd restart trigger
  - Validator startup messages
  - Gossip reconnection
  - Ledger replay progress
  - Voting resumed
```

### Grafana Metrics
- **Validator status panel**: FILL IN AFTER TESTING (did it show the node going offline?)
- **Slot production**: FILL IN AFTER TESTING (any missed slots during downtime?)
- **Vote credits**: FILL IN AFTER TESTING (gap in vote credits during recovery?)
- **Cluster TPS**: FILL IN AFTER TESTING (any impact on throughput?)

Screenshot path: `docs/screenshots/scenario1-grafana.png`

### Recovery Time
- Process killed at: FILL IN AFTER TESTING
- Process restarted at: FILL IN AFTER TESTING
- Rejoined gossip at: FILL IN AFTER TESTING
- Resumed voting at: FILL IN AFTER TESTING
- **Total recovery time**: FILL IN AFTER TESTING

### Post-Recovery Verification
```bash
# Paste output of these commands:
solana validators --url <RPC_URL>
solana gossip --url <RPC_URL>
sudo systemctl status solana-validator  # on the recovered node
```

Output:
```
FILL IN AFTER TESTING
```

### Issues Encountered
FILL IN AFTER TESTING

---

## Scenario 2: Add 4th Validator (Inventory-Only Scaling)

### Description
Demonstrate horizontal scaling by adding a 4th validator to the cluster. This involves launching a new EC2 instance, adding it to the Ansible inventory, and running the playbook with `--limit` to configure only the new node.

### Prerequisites Completed
- [ ] New EC2 instance launched (t3.medium, Ubuntu 22.04)
- [ ] Instance placed in private subnet (10.0.2.0/24)
- [ ] Attached to validators security group
- [ ] SSH key authorized
- [ ] Instance ID: FILL IN AFTER TESTING
- [ ] Public IP: FILL IN AFTER TESTING
- [ ] Private IP: FILL IN AFTER TESTING

### Command Used
```bash
bash scripts/add-validator.sh <NEW_VALIDATOR_IP> http://<RPC_IP>:8899
```

### Ansible Playbook Output
```
FILL IN AFTER TESTING

Paste relevant output from the ansible-playbook run.
Look for:
  - All tasks completed successfully
  - Any skipped or failed tasks
  - Time taken for playbook execution
```

### Journal Logs Observed
```
FILL IN AFTER TESTING

Paste relevant output from:
  ssh ubuntu@<NEW_VALIDATOR_IP> "journalctl -u solana-validator -n 50 --no-pager"

Look for:
  - Genesis fetch from bootstrap
  - Ledger replay/catchup progress
  - Gossip peer discovery
  - Voting started
```

### Grafana Metrics
- **Gossip peer count**: FILL IN AFTER TESTING (did it increase from N to N+1?)
- **Validator count panel**: FILL IN AFTER TESTING (shows 4 active validators?)
- **New validator's vote credits**: FILL IN AFTER TESTING (started accumulating?)
- **Cluster TPS**: FILL IN AFTER TESTING (any change in throughput?)

Screenshot path: `docs/screenshots/scenario2-grafana.png`

### Timing
- Ansible playbook started at: FILL IN AFTER TESTING
- Ansible playbook completed at: FILL IN AFTER TESTING
- Validator appeared in gossip at: FILL IN AFTER TESTING
- Validator started voting at: FILL IN AFTER TESTING
- **Total time to join cluster**: FILL IN AFTER TESTING

### Post-Scaling Verification
```bash
# Paste output of these commands:
solana validators --url <RPC_URL>
solana gossip --url <RPC_URL>
grep "sol-validator-4" ansible/inventory/hosts.yml
```

Output:
```
FILL IN AFTER TESTING
```

### Issues Encountered
FILL IN AFTER TESTING

---

## Scenario 3: RPC Node Replacement

### Description
Simulate an RPC node failure requiring a full replacement. Stop the RPC service, delete all ledger data, and use Ansible to redeploy from scratch. Verify the RPC node catches up and serves requests.

### Command Used
```bash
bash scripts/replace-rpc.sh http://<RPC_IP>:8899
```

### Step-by-Step Observations

#### Step 1: Service Stop
```
FILL IN AFTER TESTING

- Service stopped cleanly? (yes/no)
- Time to stop:
- RPC health endpoint response after stop:
```

#### Step 2: Ledger Deletion
```
FILL IN AFTER TESTING

- Ledger size before deletion:
- Deletion completed cleanly? (yes/no)
```

#### Step 3: Ansible Redeploy
```
FILL IN AFTER TESTING

Paste relevant ansible-playbook output.
Look for:
  - Configuration tasks
  - Service restart
  - Any errors
```

#### Step 4: Health Check Polling
```
FILL IN AFTER TESTING

- First "behind" response at:
- Catchup progress:
- First "ok" response at:
```

### Journal Logs Observed
```
FILL IN AFTER TESTING

Paste relevant output from:
  ssh ubuntu@<RPC_IP> "journalctl -u solana-rpc -n 50 --no-pager"

Look for:
  - Service start
  - Snapshot download (if applicable)
  - Ledger replay progress
  - RPC server ready
  - Health status transitions
```

### Grafana Metrics
- **RPC request latency**: FILL IN AFTER TESTING (spike during recovery?)
- **RPC slot height vs cluster**: FILL IN AFTER TESTING (catchup curve?)
- **ALB healthy targets**: FILL IN AFTER TESTING (dropped to 0, then back to 1?)

Screenshot path: `docs/screenshots/scenario3-grafana.png`

### Recovery Time
- Service stopped at: FILL IN AFTER TESTING
- Ledger deleted at: FILL IN AFTER TESTING
- Ansible started at: FILL IN AFTER TESTING
- Ansible completed at: FILL IN AFTER TESTING
- RPC healthy at: FILL IN AFTER TESTING
- **Total recovery time**: FILL IN AFTER TESTING

### Post-Replacement Verification
```bash
# Paste output of these commands:
curl -s http://<RPC_IP>:8899/health
solana slot --url http://<RPC_IP>:8899
solana validators --url http://<RPC_IP>:8899
```

Output:
```
FILL IN AFTER TESTING
```

### Issues Encountered
FILL IN AFTER TESTING

---

## Summary Table

| Scenario                  | Recovery Time | Cluster Impact | Automated? |
|---------------------------|---------------|----------------|------------|
| 1. Validator process kill | FILL IN       | FILL IN        | Yes (systemd) |
| 2. Add 4th validator      | FILL IN       | FILL IN        | Yes (Ansible) |
| 3. RPC node replacement   | FILL IN       | FILL IN        | Yes (Ansible) |
