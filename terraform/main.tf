###############################################################################
# Provider
###############################################################################
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "solana-private-cluster"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

###############################################################################
# VPC
###############################################################################
module "vpc" {
  source = "./modules/vpc"

  vpc_cidr             = var.vpc_cidr
  public_subnet_cidr   = var.public_subnet_cidr
  public_subnet_cidr_b = var.public_subnet_cidr_b
  private_subnet_cidr  = var.private_subnet_cidr
  region               = var.region
  environment          = var.environment
}

###############################################################################
# Security Groups
###############################################################################
module "security_groups" {
  source = "./modules/security-groups"

  vpc_id      = module.vpc.vpc_id
  your_ip     = var.your_ip
  environment = var.environment
}

###############################################################################
# EC2 Instances, EBS, ALB
###############################################################################
module "ec2" {
  source = "./modules/ec2"

  environment              = var.environment
  instance_type_validator  = var.instance_type_validator
  instance_type_rpc        = var.instance_type_rpc
  instance_type_faucet     = var.instance_type_faucet
  key_pair_name            = var.key_pair_name
  public_subnet_id         = module.vpc.public_subnet_id
  public_subnet_id_b       = module.vpc.public_subnet_id_b
  private_subnet_id        = module.vpc.private_subnet_id
  validators_sg_id         = module.security_groups.validators_sg_id
  rpc_sg_id                = module.security_groups.rpc_sg_id
  faucet_sg_id             = module.security_groups.faucet_sg_id
  monitoring_sg_id         = module.security_groups.monitoring_sg_id
  alb_sg_id                = module.security_groups.alb_sg_id
  vpc_id                   = module.vpc.vpc_id
  validator_count          = var.validator_count
  ledger_volume_size       = var.ledger_volume_size
  ledger_volume_iops       = var.ledger_volume_iops
  ledger_volume_throughput = var.ledger_volume_throughput
  region                   = var.region
}
