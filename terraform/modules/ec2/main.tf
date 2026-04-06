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
