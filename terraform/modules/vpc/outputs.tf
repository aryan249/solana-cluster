output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.solana.id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.public.id
}

output "public_subnet_id_b" {
  description = "ID of the second public subnet (for ALB)"
  value       = aws_subnet.public_b.id
}

output "private_subnet_id" {
  description = "ID of the private subnet"
  value       = aws_subnet.private.id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.solana.id
}

output "nat_gateway_id" {
  description = "ID of the NAT Gateway"
  value       = aws_nat_gateway.solana.id
}
