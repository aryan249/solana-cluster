###############################################################################
# Outputs — used to populate Ansible inventory
###############################################################################

output "bootstrap_public_ip" {
  description = "Public IP of the bootstrap validator"
  value       = module.ec2.bootstrap_public_ip
}

output "bootstrap_private_ip" {
  description = "Private IP of the bootstrap validator"
  value       = module.ec2.bootstrap_private_ip
}

output "validator_1_public_ip" {
  description = "Public IP of validator 1"
  value       = module.ec2.validator_public_ips[0]
}

output "validator_1_private_ip" {
  description = "Private IP of validator 1"
  value       = module.ec2.validator_private_ips[0]
}

output "validator_2_public_ip" {
  description = "Public IP of validator 2"
  value       = module.ec2.validator_public_ips[1]
}

output "validator_2_private_ip" {
  description = "Private IP of validator 2"
  value       = module.ec2.validator_private_ips[1]
}

output "validator_3_public_ip" {
  description = "Public IP of validator 3"
  value       = module.ec2.validator_public_ips[2]
}

output "validator_3_private_ip" {
  description = "Private IP of validator 3"
  value       = module.ec2.validator_private_ips[2]
}

output "rpc_public_ip" {
  description = "Public IP of the RPC node"
  value       = module.ec2.rpc_public_ip
}

output "rpc_private_ip" {
  description = "Private IP of the RPC node"
  value       = module.ec2.rpc_private_ip
}

output "faucet_public_ip" {
  description = "Public IP of the faucet"
  value       = module.ec2.faucet_public_ip
}

output "faucet_private_ip" {
  description = "Private IP of the faucet"
  value       = module.ec2.faucet_private_ip
}

output "alb_dns_name" {
  description = "DNS name of the RPC Application Load Balancer"
  value       = module.ec2.alb_dns_name
}

output "ssh_private_key_path" {
  description = "Path to the generated SSH private key"
  value       = module.ec2.private_key_path
}

output "ansible_inventory_snippet" {
  description = "Copy this into ansible/inventory/hosts.yml"
  value       = <<-EOT
    all:
      vars:
        ansible_user: ubuntu
        ansible_ssh_private_key_file: ${module.ec2.private_key_path}
        ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
      children:
        bootstrap:
          hosts:
            sol-bootstrap:
              ansible_host: ${module.ec2.bootstrap_public_ip}
              private_ip: ${module.ec2.bootstrap_private_ip}
        validators:
          hosts:
            sol-validator-1:
              ansible_host: ${module.ec2.validator_public_ips[0]}
              private_ip: ${module.ec2.validator_private_ips[0]}
            sol-validator-2:
              ansible_host: ${module.ec2.validator_public_ips[1]}
              private_ip: ${module.ec2.validator_private_ips[1]}
            sol-validator-3:
              ansible_host: ${module.ec2.validator_public_ips[2]}
              private_ip: ${module.ec2.validator_private_ips[2]}
        rpc:
          hosts:
            sol-rpc:
              ansible_host: ${module.ec2.rpc_public_ip}
              private_ip: ${module.ec2.rpc_private_ip}
        faucet:
          hosts:
            sol-faucet:
              ansible_host: ${module.ec2.faucet_public_ip}
              private_ip: ${module.ec2.faucet_private_ip}
  EOT
}
