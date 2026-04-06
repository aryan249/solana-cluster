###############################################################################
# VPC
###############################################################################
resource "aws_vpc" "solana" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "solana-cluster-vpc"
    Environment = var.environment
  }
}

###############################################################################
# Internet Gateway
###############################################################################
resource "aws_internet_gateway" "solana" {
  vpc_id = aws_vpc.solana.id

  tags = {
    Name        = "solana-cluster-igw"
    Environment = var.environment
  }
}

###############################################################################
# Public Subnet
###############################################################################
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.solana.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "solana-public-subnet"
    Environment = var.environment
  }
}

###############################################################################
# Public Subnet B (second AZ — required for ALB)
###############################################################################
resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.solana.id
  cidr_block              = var.public_subnet_cidr_b
  availability_zone       = "${var.region}b"
  map_public_ip_on_launch = true

  tags = {
    Name        = "solana-public-subnet-b"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# Private Subnet
###############################################################################
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.solana.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = "${var.region}a"

  tags = {
    Name        = "solana-private-subnet"
    Environment = var.environment
  }
}

###############################################################################
# NAT Gateway (for private subnet outbound)
###############################################################################
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "solana-nat-eip"
    Environment = var.environment
  }
}

resource "aws_nat_gateway" "solana" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name        = "solana-nat-gw"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.solana]
}

###############################################################################
# Route Tables
###############################################################################

# Public route table — routes to IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.solana.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.solana.id
  }

  tags = {
    Name        = "solana-public-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private route table — routes to NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.solana.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.solana.id
  }

  tags = {
    Name        = "solana-private-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
