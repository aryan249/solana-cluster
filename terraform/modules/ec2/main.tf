###############################################################################
# Data Sources
###############################################################################
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

###############################################################################
# Key Pair
###############################################################################
resource "tls_private_key" "solana" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "solana" {
  key_name   = var.key_pair_name
  public_key = tls_private_key.solana.public_key_openssh

  tags = {
    Name        = var.key_pair_name
    Environment = var.environment
  }
}

resource "local_file" "private_key" {
  content         = tls_private_key.solana.private_key_pem
  filename        = "${path.root}/solana-cluster-key.pem"
  file_permission = "0400"
}

###############################################################################
# IAM Instance Profile (SSM access)
###############################################################################
resource "aws_iam_role" "solana_instance" {
  name_prefix = "solana-instance-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "solana-instance-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.solana_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "solana" {
  name_prefix = "solana-instance-"
  role        = aws_iam_role.solana_instance.name

  tags = {
    Name        = "solana-instance-profile"
    Environment = var.environment
  }
}

###############################################################################
# Bootstrap Validator
###############################################################################
resource "aws_instance" "bootstrap" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type_validator
  key_name               = aws_key_pair.solana.key_name
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.validators_sg_id, var.monitoring_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.solana.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name        = "sol-bootstrap"
    Role        = "bootstrap"
    Environment = var.environment
  }
}

resource "aws_ebs_volume" "bootstrap_ledger" {
  availability_zone = aws_instance.bootstrap.availability_zone
  size              = var.ledger_volume_size
  type              = "gp3"
  iops              = var.ledger_volume_iops
  throughput        = var.ledger_volume_throughput

  tags = {
    Name        = "sol-bootstrap-ledger"
    Environment = var.environment
  }
}

resource "aws_volume_attachment" "bootstrap_ledger" {
  device_name = "/dev/xvdb"
  volume_id   = aws_ebs_volume.bootstrap_ledger.id
  instance_id = aws_instance.bootstrap.id
}

resource "aws_eip" "bootstrap" {
  instance = aws_instance.bootstrap.id
  domain   = "vpc"

  tags = {
    Name        = "sol-bootstrap-eip"
    Environment = var.environment
  }
}

###############################################################################
# Validators
###############################################################################
resource "aws_instance" "validators" {
  count                  = var.validator_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type_validator
  key_name               = aws_key_pair.solana.key_name
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.validators_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.solana.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name        = "sol-validator-${count.index + 1}"
    Role        = "validator"
    Environment = var.environment
  }
}

resource "aws_ebs_volume" "validator_ledger" {
  count             = var.validator_count
  availability_zone = aws_instance.validators[count.index].availability_zone
  size              = var.ledger_volume_size
  type              = "gp3"
  iops              = var.ledger_volume_iops
  throughput        = var.ledger_volume_throughput

  tags = {
    Name        = "sol-validator-${count.index + 1}-ledger"
    Environment = var.environment
  }
}

resource "aws_volume_attachment" "validator_ledger" {
  count       = var.validator_count
  device_name = "/dev/xvdb"
  volume_id   = aws_ebs_volume.validator_ledger[count.index].id
  instance_id = aws_instance.validators[count.index].id
}

resource "aws_eip" "validators" {
  count    = var.validator_count
  instance = aws_instance.validators[count.index].id
  domain   = "vpc"

  tags = {
    Name        = "sol-validator-${count.index + 1}-eip"
    Environment = var.environment
  }
}

###############################################################################
# RPC Node
###############################################################################
resource "aws_instance" "rpc" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type_rpc
  key_name               = aws_key_pair.solana.key_name
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [var.rpc_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.solana.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name        = "sol-rpc"
    Role        = "rpc"
    Environment = var.environment
  }
}

resource "aws_ebs_volume" "rpc_ledger" {
  availability_zone = aws_instance.rpc.availability_zone
  size              = var.ledger_volume_size
  type              = "gp3"
  iops              = var.ledger_volume_iops
  throughput        = var.ledger_volume_throughput

  tags = {
    Name        = "sol-rpc-ledger"
    Environment = var.environment
  }
}

resource "aws_volume_attachment" "rpc_ledger" {
  device_name = "/dev/xvdb"
  volume_id   = aws_ebs_volume.rpc_ledger.id
  instance_id = aws_instance.rpc.id
}

resource "aws_eip" "rpc" {
  instance = aws_instance.rpc.id
  domain   = "vpc"

  tags = {
    Name        = "sol-rpc-eip"
    Environment = var.environment
  }
}

###############################################################################
# Faucet
###############################################################################
resource "aws_instance" "faucet" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type_faucet
  key_name               = aws_key_pair.solana.key_name
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.faucet_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.solana.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name        = "sol-faucet"
    Role        = "faucet"
    Environment = var.environment
  }
}

resource "aws_eip" "faucet" {
  instance = aws_instance.faucet.id
  domain   = "vpc"

  tags = {
    Name        = "sol-faucet-eip"
    Environment = var.environment
  }
}
