output "head_public_ip" {
  value = aws_instance.head.public_ip
}

output "nodes" {
  description = "Slurm node name to private IP."
  value       = local.hosts
}

output "slurm_node_shape" {
  description = "What each compute node advertises to Slurm."
  value = {
    instance_type    = var.compute_instance_type
    cpus             = local.compute_cpus
    cores_per_socket = local.compute_cores
    threads_per_core = local.compute_threads
    real_memory      = local.compute_mem_mib
  }
}

output "ssh_config" {
  description = "Append-ready ssh_config stanzas; scripts/ssh-config.sh writes them. Claude Science uses the first (unprivileged agent); the operator uses -admin."
  value       = <<-EOT
    Host ${var.cluster_name}
      HostName ${aws_instance.head.public_ip}
      User agent
      IdentityFile ~/.ssh/ehpc_agent_ed25519
      IdentitiesOnly yes
      ForwardAgent no
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ~/.ssh/known_hosts.${var.cluster_name}

    Host ${var.cluster_name}-admin
      HostName ${aws_instance.head.public_ip}
      User ubuntu
      IdentityFile ~/.ssh/ehpc_ed25519
      IdentitiesOnly yes
      ForwardAgent no
      StrictHostKeyChecking accept-new
      UserKnownHostsFile ~/.ssh/known_hosts.${var.cluster_name}
  EOT
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.cluster.dashboard_name}"
}

output "self_terminates_after_hours" {
  value = var.ttl_hours
}
