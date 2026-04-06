output "validators_sg_id" {
  description = "Security group ID for validators"
  value       = aws_security_group.validators.id
}

output "rpc_sg_id" {
  description = "Security group ID for RPC node"
  value       = aws_security_group.rpc.id
}

output "faucet_sg_id" {
  description = "Security group ID for faucet"
  value       = aws_security_group.faucet.id
}

output "monitoring_sg_id" {
  description = "Security group ID for monitoring"
  value       = aws_security_group.monitoring.id
}

output "alb_sg_id" {
  description = "Security group ID for ALB"
  value       = aws_security_group.alb.id
}
