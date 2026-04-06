variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "public_subnet_cidr_b" {
  description = "CIDR block for the second public subnet (ALB requires 2 AZs)"
  type        = string
}

variable "environment" {
  description = "Environment tag"
  type        = string
}
