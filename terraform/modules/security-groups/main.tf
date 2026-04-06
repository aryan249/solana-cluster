###############################################################################
# Security Group: ALB
###############################################################################
resource "aws_security_group" "alb" {
  name_prefix = "solana-alb-"
  description = "Security group for the Application Load Balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "sg-solana-alb"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Security Group: Monitoring
###############################################################################
resource "aws_security_group" "monitoring" {
  name_prefix = "solana-monitoring-"
  description = "Security group for monitoring (Prometheus + Grafana)"
  vpc_id      = var.vpc_id

  ingress {
    description = "Prometheus UI"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.your_ip]
  }

  ingress {
    description = "Grafana UI"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.your_ip]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "sg-solana-monitoring"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Security Group: Validators (bootstrap + validators)
###############################################################################
resource "aws_security_group" "validators" {
  name_prefix = "solana-validators-"
  description = "Security group for Solana validators and bootstrap node"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_ip]
  }

  # All Solana ports within VPC (gossip, TPU, TVU, RPC, dynamic range)
  ingress {
    description = "All Solana ports within VPC TCP"
    from_port   = 8000
    to_port     = 8020
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    description = "All Solana ports within VPC UDP"
    from_port   = 8000
    to_port     = 8020
    protocol    = "udp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # Solana uses ephemeral UDP ports for gossip/repair protocol
  ingress {
    description = "Ephemeral UDP ports for Solana protocol within VPC"
    from_port   = 1024
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    description = "Ephemeral TCP ports for Solana protocol within VPC"
    from_port   = 1024
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    description = "RPC port within VPC"
    from_port   = 8899
    to_port     = 8900
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # Prometheus scrape from monitoring
  ingress {
    description     = "Prometheus metrics scrape"
    from_port       = 9900
    to_port         = 9900
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  ingress {
    description = "Metrics port within VPC"
    from_port   = 9900
    to_port     = 9900
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "sg-solana-validators"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Self-referencing rules for validator-to-validator traffic
resource "aws_security_group_rule" "validators_gossip_tcp_self" {
  type                     = "ingress"
  from_port                = 8001
  to_port                  = 8001
  protocol                 = "tcp"
  description              = "Gossip TCP between validators"
  security_group_id        = aws_security_group.validators.id
  source_security_group_id = aws_security_group.validators.id
}

resource "aws_security_group_rule" "validators_gossip_udp_self" {
  type                     = "ingress"
  from_port                = 8001
  to_port                  = 8001
  protocol                 = "udp"
  description              = "Gossip UDP between validators"
  security_group_id        = aws_security_group.validators.id
  source_security_group_id = aws_security_group.validators.id
}

resource "aws_security_group_rule" "validators_tpu_self" {
  type                     = "ingress"
  from_port                = 8004
  to_port                  = 8004
  protocol                 = "udp"
  description              = "TPU between validators"
  security_group_id        = aws_security_group.validators.id
  source_security_group_id = aws_security_group.validators.id
}

resource "aws_security_group_rule" "validators_tvu_self" {
  type                     = "ingress"
  from_port                = 8005
  to_port                  = 8005
  protocol                 = "udp"
  description              = "TVU between validators"
  security_group_id        = aws_security_group.validators.id
  source_security_group_id = aws_security_group.validators.id
}

resource "aws_security_group_rule" "validators_tpu_forwards_self" {
  type                     = "ingress"
  from_port                = 8006
  to_port                  = 8006
  protocol                 = "udp"
  description              = "TPU forwards between validators"
  security_group_id        = aws_security_group.validators.id
  source_security_group_id = aws_security_group.validators.id
}

resource "aws_security_group_rule" "validators_tvu_quic_self" {
  type                     = "ingress"
  from_port                = 8008
  to_port                  = 8008
  protocol                 = "udp"
  description              = "TVU QUIC between validators"
  security_group_id        = aws_security_group.validators.id
  source_security_group_id = aws_security_group.validators.id
}

# RPC gossip to validators
resource "aws_security_group_rule" "validators_gossip_tcp_from_rpc" {
  type                     = "ingress"
  from_port                = 8001
  to_port                  = 8001
  protocol                 = "tcp"
  description              = "Gossip TCP from RPC"
  security_group_id        = aws_security_group.validators.id
  source_security_group_id = aws_security_group.rpc.id
}

resource "aws_security_group_rule" "validators_gossip_udp_from_rpc" {
  type                     = "ingress"
  from_port                = 8001
  to_port                  = 8001
  protocol                 = "udp"
  description              = "Gossip UDP from RPC"
  security_group_id        = aws_security_group.validators.id
  source_security_group_id = aws_security_group.rpc.id
}

# Dynamic port range for Solana protocol
resource "aws_security_group_rule" "validators_dynamic_udp_self" {
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8020
  protocol                 = "udp"
  description              = "Dynamic port range between validators"
  security_group_id        = aws_security_group.validators.id
  source_security_group_id = aws_security_group.validators.id
}

resource "aws_security_group_rule" "validators_dynamic_tcp_self" {
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8020
  protocol                 = "tcp"
  description              = "Dynamic port range TCP between validators"
  security_group_id        = aws_security_group.validators.id
  source_security_group_id = aws_security_group.validators.id
}

###############################################################################
# Security Group: RPC
###############################################################################
resource "aws_security_group" "rpc" {
  name_prefix = "solana-rpc-"
  description = "Security group for the Solana RPC node"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_ip]
  }

  # Gossip from anywhere (RPC needs to be reachable)
  ingress {
    description = "Gossip UDP"
    from_port   = 8001
    to_port     = 8001
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Gossip TCP"
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # JSON-RPC from ALB only
  ingress {
    description     = "JSON-RPC from ALB"
    from_port       = 8899
    to_port         = 8899
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # WebSocket from ALB only
  ingress {
    description     = "WebSocket from ALB"
    from_port       = 8900
    to_port         = 8900
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Also allow direct RPC access from your IP (for Ansible/scripts)
  ingress {
    description = "JSON-RPC direct"
    from_port   = 8899
    to_port     = 8899
    protocol    = "tcp"
    cidr_blocks = [var.your_ip]
  }

  ingress {
    description = "WebSocket direct"
    from_port   = 8900
    to_port     = 8900
    protocol    = "tcp"
    cidr_blocks = [var.your_ip]
  }

  # Prometheus scrape
  ingress {
    description     = "Prometheus metrics scrape"
    from_port       = 9900
    to_port         = 9900
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  # Dynamic port range for gossip/repair
  ingress {
    description = "Dynamic port range UDP"
    from_port   = 8000
    to_port     = 8020
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Dynamic port range TCP"
    from_port   = 8000
    to_port     = 8020
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "sg-solana-rpc"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Security Group: Faucet
###############################################################################
resource "aws_security_group" "faucet" {
  name_prefix = "solana-faucet-"
  description = "Security group for the Solana faucet"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.your_ip]
  }

  # Prometheus scrape
  ingress {
    description     = "Prometheus metrics scrape"
    from_port       = 9900
    to_port         = 9900
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  # Faucet port from within VPC
  ingress {
    description = "Faucet service from VPC"
    from_port   = 9900
    to_port     = 9900
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "sg-solana-faucet"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}
