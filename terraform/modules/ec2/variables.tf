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
