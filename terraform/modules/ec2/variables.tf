variable "environment" {
  description = "Environment tag"
  type        = string
}

variable "instance_type_validator" {
  description = "Instance type for validators and bootstrap"
  type        = string
}

variable "key_pair_name" {
  description = "AWS key pair name"
  type        = string
}

variable "private_subnet_id" {
  description = "Private subnet ID"
  type        = string
}

variable "validators_sg_id" {
  description = "Security group ID for validators"
  type        = string
}

variable "monitoring_sg_id" {
  description = "Security group ID for monitoring"
  type        = string
}

variable "instance_type_rpc" {
  description = "Instance type for the RPC node"
  type        = string
}

variable "instance_type_faucet" {
  description = "Instance type for the faucet"
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet ID"
  type        = string
}

variable "rpc_sg_id" {
  description = "Security group ID for RPC"
  type        = string
}

variable "faucet_sg_id" {
  description = "Security group ID for faucet"
  type        = string
}

variable "validator_count" {
  description = "Number of validators (excluding bootstrap)"
  type        = number
}

variable "ledger_volume_size" {
  description = "EBS volume size in GB for ledger"
  type        = number
}

variable "ledger_volume_iops" {
  description = "Provisioned IOPS for ledger EBS"
  type        = number
}

variable "ledger_volume_throughput" {
  description = "Throughput in MB/s for ledger EBS"
  type        = number
}
