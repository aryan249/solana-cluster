# Solana Private Cluster Architecture

## Network Topology

```
                          ┌──────────────────────────────────────────────────────────────┐
                          │                     AWS VPC (10.0.0.0/16)                    │
                          │                        ap-south-1                            │
                          │                                                              │
   ┌─────────┐           │  ┌──────────────────────────────────────────────────────┐     │
   │ Internet│           │  │          Public Subnet A (10.0.1.0/24)              │     │
   │         │           │  │                  ap-south-1a                         │     │
   └────┬────┘           │  │                                                      │     │
        │                │  │  ┌──────────────┐  ┌──────────────┐                  │     │
        │     ┌──────┐   │  │  │  Bootstrap    │  │   Faucet     │                  │     │
        ├─────┤ IGW  ├───┤  │  │  Validator    │  │  (t2.micro)  │                  │     │
        │     └──────┘   │  │  │ (t3.medium)   │  │              │                  │     │
        │                │  │  │              │  │  Port: 9900   │                  │     │
        │                │  │  │  Ports:       │  └──────────────┘                  │     │
        │                │  │  │   8001 gossip │                                    │     │
        │                │  │  │   8899 RPC    │  ┌──────────────────────────────┐  │     │
        │                │  │  │   9900 metrics│  │   Monitoring Stack           │  │     │
        │                │  │  │              │  │   (on Bootstrap node)        │  │     │
        │                │  │  │  Genesis +    │  │                              │  │     │
        │                │  │  │  Ledger       │  │  Prometheus :9090            │  │     │
        │                │  │  └──────────────┘  │  Grafana     :3000            │  │     │
        │                │  │                     │  (Docker Compose)            │  │     │
        │                │  │                     └──────────────────────────────┘  │     │
        │                │  └──────────────────────────────────────────────────────┘     │
        │                │                                                              │
        │                │  ┌──────────────────────────────────────────────────────┐     │
        │                │  │          Public Subnet B (10.0.3.0/24)              │     │
        │                │  │                  ap-south-1b                         │     │
        │                │  │                                                      │     │
        │  ┌─────────┐   │  │          (Used by ALB for cross-AZ routing)         │     │
        ├──┤  ALB    ├───┤  │                                                      │     │
        │  │ :8899   │   │  └──────────────────────────────────────────────────────┘     │
        │  └─────────┘   │                                                              │
        │                │  ┌──────────────────────────────────────────────────────┐     │
        │                │  │         Private Subnet (10.0.2.0/24)                │     │
        │                │  │                  ap-south-1a                         │     │
        │                │  │                                                      │     │
        │                │  │  ┌──────────────┐  ┌──────────────┐                  │     │
        │                │  │  │ Validator 1   │  │ Validator 2   │                  │     │
        │                │  │  │ (t3.medium)   │  │ (t3.medium)   │                  │     │
        │                │  │  │              │  │              │                  │     │
        │                │  │  │ 100GB gp3 EBS│  │ 100GB gp3 EBS│                  │     │
        │                │  │  │ 3000 IOPS    │  │ 3000 IOPS    │                  │     │
        │                │  │  └──────────────┘  └──────────────┘                  │     │
        │                │  │                                                      │     │
        │                │  │  ┌──────────────┐  ┌──────────────┐                  │     │
        │                │  │  │ Validator 3   │  │ RPC Node     │                  │     │
        │  ┌─────────┐   │  │  │ (t3.medium)   │  │ (t3.medium)   │                  │     │
        └──┤ NAT GW  ├───┤  │  │              │  │              │                  │     │
           └─────────┘   │  │  │ 100GB gp3 EBS│  │ 100GB gp3 EBS│                  │     │
                          │  │  │ 3000 IOPS    │  │ 3000 IOPS    │                  │     │
                          │  │  └──────────────┘  └──────────────┘                  │     │
                          │  └──────────────────────────────────────────────────────┘     │
                          └──────────────────────────────────────────────────────────────┘
```

## Component Table

| Component            | Instance Type | Count | Subnet  | Security Group   | EBS Volume           | Key Ports                          |
|----------------------|---------------|-------|---------|------------------|----------------------|------------------------------------|
| Bootstrap Validator  | t3.medium     | 1     | Public  | validators-sg    | 100GB gp3, 3000 IOPS | 8001 (gossip), 8899 (RPC), 9900 (metrics) |
| Validator 1-3        | t3.medium     | 3     | Private | validators-sg    | 100GB gp3, 3000 IOPS | 8001 (gossip), 8004 (TPU), 8005 (TVU) |
| RPC Node             | t3.medium     | 1     | Private | rpc-sg           | 100GB gp3, 3000 IOPS | 8899 (RPC), 8900 (WebSocket)        |
| Faucet               | t2.micro      | 1     | Public  | faucet-sg        | Root volume only      | 9900 (faucet API)                   |
| ALB                  | Managed       | 1     | Public  | alb-sg           | N/A                  | 8899 (forwarding to RPC)            |
| Prometheus           | (on Bootstrap)| 1     | Public  | monitoring-sg    | N/A                  | 9090                                |
| Grafana              | (on Bootstrap)| 1     | Public  | monitoring-sg    | N/A                  | 3000                                |
| NAT Gateway          | Managed       | 1     | Public  | N/A              | N/A                  | All outbound                        |
| Internet Gateway     | Managed       | 1     | N/A     | N/A              | N/A                  | All inbound/outbound                |

## Network Flows

### Gossip Protocol (UDP)
Every node participates in Solana's gossip protocol over port 8001. Validators in the private subnet communicate with the bootstrap validator and each other via gossip. The NAT gateway enables private subnet nodes to reach the bootstrap validator's public gossip endpoint during initial contact; once connected, gossip proceeds over private IPs within the VPC.

### Transaction Flow
1. Client sends a transaction to the ALB on port 8899
2. ALB forwards to the RPC node in the private subnet
3. RPC node forwards the transaction via TPU (port 8004) to the current leader validator
4. Leader validator processes and includes the transaction in a block
5. Block propagates to all validators via Turbine (TVU port 8005)
6. Validators vote on the block, and after sufficient confirmations the transaction is finalized

### RPC Access
External clients connect through the Application Load Balancer, which performs health checks on the RPC node and forwards traffic. The ALB spans two availability zones (public subnets A and B) as required by AWS. The RPC node itself lives in the private subnet and is not directly internet-accessible.

### Monitoring Data Flow
1. Each Solana node exposes metrics on port 9900 (Prometheus exposition format)
2. Prometheus (running on the bootstrap node via Docker Compose) scrapes all nodes every 15 seconds
3. Grafana reads from the Prometheus data source and renders dashboards
4. Grafana is accessible on port 3000 of the bootstrap node's public IP

## Security Groups

### validators-sg
- Inbound: SSH (22) from deployer IP, all traffic from within VPC CIDR, gossip (8001/UDP) from 0.0.0.0/0
- Outbound: All traffic

### rpc-sg
- Inbound: SSH (22) from deployer IP, RPC (8899/TCP) from ALB security group, all traffic from VPC CIDR
- Outbound: All traffic

### faucet-sg
- Inbound: SSH (22) from deployer IP, faucet API (9900/TCP) from VPC CIDR
- Outbound: All traffic

### alb-sg
- Inbound: 8899/TCP from 0.0.0.0/0
- Outbound: 8899/TCP to rpc-sg

### monitoring-sg
- Inbound: Grafana (3000/TCP) from deployer IP, Prometheus (9090/TCP) from deployer IP
- Outbound: 9900/TCP to VPC CIDR (scrape targets)

## Monitoring Architecture

The monitoring stack runs on the bootstrap validator node using Docker Compose with two containers:

- **Prometheus**: Scrapes `/metrics` endpoints from all cluster nodes (bootstrap, validators 1-3, RPC, faucet) on port 9900. Scrape interval is 15 seconds. Configuration is templated by Ansible (`prometheus.yml.j2`) to dynamically include all inventory hosts.

- **Grafana**: Pre-configured with Prometheus as a data source via provisioning files. Ships with a custom Solana cluster dashboard (`solana-cluster-dashboard.json`) that displays:
  - Cluster slot height and epoch progress
  - Per-validator vote credits and skip rate
  - Transaction throughput (TPS)
  - RPC request latency
  - System metrics (CPU, memory, disk I/O)
  - Leader schedule and slot production

Both services persist data to Docker volumes and restart automatically (`restart: unless-stopped`).
