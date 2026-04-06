output "bootstrap_public_ip" {
  description = "Public IP of the bootstrap validator"
  value       = aws_eip.bootstrap.public_ip
}

output "bootstrap_private_ip" {
  description = "Private IP of the bootstrap validator"
  value       = aws_instance.bootstrap.private_ip
}

output "validator_public_ips" {
  description = "Public IPs of all validators"
  value       = aws_eip.validators[*].public_ip
}

output "validator_private_ips" {
  description = "Private IPs of all validators"
  value       = aws_instance.validators[*].private_ip
}

output "rpc_public_ip" {
  description = "Public IP of the RPC node"
  value       = aws_eip.rpc.public_ip
}

output "rpc_private_ip" {
  description = "Private IP of the RPC node"
  value       = aws_instance.rpc.private_ip
}

output "faucet_public_ip" {
  description = "Public IP of the faucet"
  value       = aws_eip.faucet.public_ip
}

output "faucet_private_ip" {
  description = "Private IP of the faucet"
  value       = aws_instance.faucet.private_ip
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.rpc.dns_name
}

output "private_key_path" {
  description = "Path to the generated SSH private key"
  value       = local_file.private_key.filename
}
