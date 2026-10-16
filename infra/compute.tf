# Head node: slurmctld, slurmdbd + MariaDB (job accounting), the NFS export
# that gives every node the same /shared, and the login shell Claude Science
# connects to. Compute nodes: slurmd in configless mode, pulling slurm.conf
# from the controller. Private IPs are fixed so slurm.conf renders at plan time.

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_ec2_instance_type" "compute" {
  instance_type = var.compute_instance_type
}

locals {
  head_ip = cidrhost(local.subnet_cidr, 10)
  compute_nodes = {
    for i in range(var.compute_count) : format("compute-%d", i + 1) => cidrhost(local.subnet_cidr, 11 + i)
  }
  hosts = merge({ head = local.head_ip }, local.compute_nodes)

  # Slurm must be told the real core/thread layout. Given only CPUs=2 on a
  # 1-core, 2-thread instance it assumes two single-thread sockets, and the
  # job cgroup ends up holding one of the two vCPUs (see docs/worklog.md).
  compute_cpus    = data.aws_ec2_instance_type.compute.default_vcpus
  compute_cores   = data.aws_ec2_instance_type.compute.default_cores
  compute_threads = data.aws_ec2_instance_type.compute.default_threads_per_core

  # Leave ~15% of RAM to the OS so slurmd never reports less than configured.
  compute_mem_mib = floor(data.aws_ec2_instance_type.compute.memory_size * 0.85)
  ttl_minutes     = var.ttl_hours * 60
  # The agent user is the same UID everywhere, so NFS ownership and Slurm
  # job credentials agree across nodes.
  agent_uid        = 2001
  munge_param_root = "${local.param_prefix}munge-key"

  # Apptainer from its GitHub release, pinned by version and checksum. The
  # non-setuid build runs containers in user namespaces; its .deb ships the
  # AppArmor profile Ubuntu 24.04 needs for that.
  apptainer = {
    url    = "https://github.com/apptainer/apptainer/releases/download/v1.5.4/apptainer_1.5.4_amd64.deb"
    sha256 = "281cf9bd68f16b6f7c34a3a94d77668bc327b9c09db0412ce7890162734a97f7"
  }

  slurm_conf = templatefile("${path.module}/templates/slurm.conf.tftpl", {
    cluster_name    = var.cluster_name
    head_ip         = local.head_ip
    compute_nodes   = local.compute_nodes
    cpus            = local.compute_cpus
    cores           = local.compute_cores
    threads         = local.compute_threads
    real_memory     = local.compute_mem_mib
    def_mem_per_cpu = floor(local.compute_mem_mib / local.compute_cpus)
    max_time_hours  = var.ttl_hours
  })

  common_files = {
    hosts_file = join("\n", concat(
      ["127.0.0.1 localhost"],
      [for name, ip in local.hosts : "${ip} ${name}"],
      [""],
    ))
    profile_env = file("${path.module}/templates/ehpc-profile.sh")
    agent_uid   = local.agent_uid
    agent_egress_nft = templatefile("${path.module}/templates/agent-egress.nft.tftpl", {
      agent_uid = local.agent_uid
      vpc_cidr  = var.vpc_cidr
    })
  }

  # The workload package ships with the cluster so every run uses the
  # reviewed code in this repo, not something typed into a prompt. Plain
  # text, not per-file gzip: user data is gzipped as a whole, and that one
  # pass compresses across files (EC2 caps user data at 16 KiB).
  workload_files = {
    for f in fileset("${path.module}/../workloads", "**/*.{py,sh,sbatch,txt,def}") :
    f => file("${path.module}/../workloads/${f}")
    if !startswith(f, "tests/")
  }
}

resource "aws_key_pair" "operator" {
  key_name_prefix = "${var.cluster_name}-operator-"
  public_key      = var.ssh_public_key
}

resource "aws_instance" "head" {
  ami                         = data.aws_ssm_parameter.ubuntu.insecure_value
  instance_type               = var.head_instance_type
  subnet_id                   = aws_subnet.cluster.id
  private_ip                  = local.head_ip
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.cluster.id, aws_security_group.ssh.id]
  iam_instance_profile        = aws_iam_instance_profile.head.name
  key_name                    = aws_key_pair.operator.key_name

  # Powering off from inside the OS terminates the instance: the TTL
  # shutdown scheduled at boot is what makes the cluster ephemeral.
  instance_initiated_shutdown_behavior = "terminate"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  dynamic "credit_specification" {
    for_each = startswith(var.head_instance_type, "t") ? [1] : []
    content {
      cpu_credits = "standard" # no surprise charges for burst above baseline
    }
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/head.yaml.tftpl", merge(local.common_files, {
    vpc_cidr             = var.vpc_cidr
    ttl_minutes          = local.ttl_minutes
    slurm_conf           = local.slurm_conf
    cgroup_conf          = file("${path.module}/templates/cgroup.conf")
    workload_files       = local.workload_files
    agent_ssh_public_key = var.agent_ssh_public_key
    squid_conf = templatefile("${path.module}/templates/squid.conf.tftpl", {
      vpc_cidr  = var.vpc_cidr
      allowlist = var.agent_egress_allowlist
    })
    esm_python = file("${path.module}/templates/esm-python.sh")
    init_script = templatefile("${path.module}/templates/head-init.sh.tftpl", {
      region           = var.region
      cluster_name     = var.cluster_name
      munge_param_root = local.munge_param_root
      apptainer_url    = local.apptainer.url
      apptainer_sha256 = local.apptainer.sha256
    })
  })))
  user_data_replace_on_change = true

  tags = {
    Name = "${var.cluster_name}-head"
    Role = "head"
  }
}

resource "aws_instance" "compute" {
  for_each = local.compute_nodes

  ami                         = data.aws_ssm_parameter.ubuntu.insecure_value
  instance_type               = var.compute_instance_type
  subnet_id                   = aws_subnet.cluster.id
  private_ip                  = each.value
  associate_public_ip_address = true # egress only; no ingress rule admits the internet
  vpc_security_group_ids      = [aws_security_group.cluster.id]
  iam_instance_profile        = aws_iam_instance_profile.compute.name
  key_name                    = aws_key_pair.operator.key_name

  instance_initiated_shutdown_behavior = "terminate"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  dynamic "credit_specification" {
    for_each = startswith(var.compute_instance_type, "t") ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  # The head's instance ID names the key this node waits for, so a node can
  # never pick up a key left behind by an earlier cluster.
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/compute.yaml.tftpl", merge(local.common_files, {
    node_name   = each.key
    ttl_minutes = local.ttl_minutes
    init_script = templatefile("${path.module}/templates/compute-init.sh.tftpl", {
      region           = var.region
      munge_param      = "${local.munge_param_root}/${aws_instance.head.id}"
      apptainer_url    = local.apptainer.url
      apptainer_sha256 = local.apptainer.sha256
    })
  })))
  user_data_replace_on_change = true

  tags = {
    Name = "${var.cluster_name}-${each.key}"
    Role = "compute"
  }
}
