variable "vpc_id" {
  description = "VPC ID to create security groups in"
  type        = string
}

variable "your_ip" {
  description = "Your public IP in CIDR notation for SSH access"
  type        = string
}

variable "environment" {
  description = "Environment tag"
  type        = string
}
