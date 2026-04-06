variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "your_ip" {
  description = "Your public IP in CIDR notation for SSH access (e.g., 203.0.113.10/32)"
  type        = string
}

variable "instance_type_validator" {
  description = "EC2 instance type for validators and bootstrap"
  type        = string
  default     = "t3.medium"
}

variable "instance_type_rpc" {
  description = "EC2 instance type for the RPC node"
  type        = string
  default     = "t3.medium"
}

variable "instance_type_faucet" {
  description = "EC2 instance type for the faucet"
  type        = string
  default     = "t2.micro"
}

variable "ledger_volume_size" {
  description = "EBS volume size in GB for ledger storage"
  type        = number
  default     = 100
}

variable "ledger_volume_iops" {
  description = "Provisioned IOPS for ledger EBS volumes"
  type        = number
  default     = 3000
}

variable "ledger_volume_throughput" {
  description = "Throughput in MB/s for ledger EBS volumes"
  type        = number
  default     = 125
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "private-testnet"
}

variable "key_pair_name" {
  description = "Name for the AWS key pair"
  type        = string
  default     = "solana-cluster-key"
}

variable "validator_count" {
  description = "Number of validators (excluding bootstrap)"
  type        = number
  default     = 3
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "public_subnet_cidr_b" {
  description = "CIDR block for the second public subnet (ALB needs 2 AZs)"
  type        = string
  default     = "10.0.3.0/24"
}
