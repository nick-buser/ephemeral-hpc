# Security and cost guardrails, checked against a mocked AWS provider so they
# run in CI with no cloud credentials. `command = apply` is safe here: the
# mock provider creates nothing.

mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = {
      default_vcpus            = 2
      default_cores            = 1
      default_threads_per_core = 2
      memory_size              = 8192
    }
  }
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-2a", "us-east-2b", "us-east-2c"]
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }
  mock_resource "aws_instance" {
    defaults = {
      id        = "i-0123456789abcdef0"
      public_ip = "203.0.113.10"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-2:123456789012:log-group:/ehpc/vpc-flow"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/ehpc-test"
    }
  }
}

variables {
  admin_cidrs          = ["203.0.113.7/32"]
  ssh_public_key       = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTerraformTestsOnly000000000000000 test"
  agent_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeAgentKeyForTerraformTestsOnly0000000000 agent"
}

run "nodes_require_imdsv2_encrypt_disks_and_self_terminate" {
  command = apply

  assert {
    condition = alltrue(concat(
      [aws_instance.head.metadata_options[0].http_tokens == "required"],
      [for n in aws_instance.compute : n.metadata_options[0].http_tokens == "required"],
    ))
    error_message = "Every node must require IMDSv2 session tokens."
  }

  assert {
    condition = alltrue(concat(
      [aws_instance.head.root_block_device[0].encrypted],
      [for n in aws_instance.compute : n.root_block_device[0].encrypted],
    ))
    error_message = "Every root volume must be encrypted."
  }

  assert {
    condition = alltrue(concat(
      [aws_instance.head.instance_initiated_shutdown_behavior == "terminate"],
      [for n in aws_instance.compute : n.instance_initiated_shutdown_behavior == "terminate"],
    ))
    error_message = "Powering off must terminate the node, or the TTL leaves stopped instances behind."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.idle_terminate) == 1 + var.compute_count
    error_message = "Every node needs an idle-terminate alarm."
  }

  assert {
    condition     = aws_instance.head.credit_specification[0].cpu_credits == "standard"
    error_message = "Burstable instances must not run in unlimited-credit mode."
  }

  # EC2 rejects user data over 16 KiB before base64. The head node carries
  # the workload code, so this is the limit that grows with the repo.
  assert {
    condition     = ceil(length(aws_instance.head.user_data_base64) * 3 / 4) < 16384
    error_message = "Head user data is over EC2's 16 KiB limit."
  }
}

run "ttl_is_enforced_outside_the_instances" {
  command = apply

  assert {
    condition     = length(aws_scheduler_schedule.ttl) == 1 + var.compute_count
    error_message = "Every node needs an EventBridge TTL that root on the node cannot cancel."
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.ttl_terminate.statement) == 1 &&
      tolist(data.aws_iam_policy_document.ttl_terminate.statement)[0].actions == toset(["ec2:TerminateInstances"])
    )
    error_message = "The TTL role may terminate instances and nothing else."
  }
}

run "agent_key_must_differ_from_operator_key" {
  command = plan

  variables {
    agent_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTerraformTestsOnly000000000000000 reused"
  }

  expect_failures = [var.agent_ssh_public_key]
}

run "ssh_is_open_only_to_admin_cidrs_and_only_on_the_head" {
  command = apply

  assert {
    condition     = [for r in aws_vpc_security_group_ingress_rule.ssh : r.cidr_ipv4] == ["203.0.113.7/32"]
    error_message = "SSH ingress must come only from admin_cidrs."
  }

  assert {
    condition     = alltrue([for n in aws_instance.compute : !contains(tolist(n.vpc_security_group_ids), aws_security_group.ssh.id)])
    error_message = "Compute nodes must not carry the SSH security group."
  }

  assert {
    condition     = !aws_subnet.cluster.map_public_ip_on_launch
    error_message = "Public IPs must be opt-in per instance, not a subnet default."
  }
}

run "slurm_node_shape_follows_the_instance_type" {
  command = apply

  assert {
    condition     = output.slurm_node_shape.cpus == 2 && output.slurm_node_shape.real_memory == 6963
    error_message = "Slurm must advertise the instance's vCPUs and ~85% of its memory."
  }

  assert {
    condition = (
      output.slurm_node_shape.cores_per_socket == 1 &&
      output.slurm_node_shape.threads_per_core == 2 &&
      output.slurm_node_shape.cores_per_socket * output.slurm_node_shape.threads_per_core == output.slurm_node_shape.cpus
    )
    error_message = "Slurm must get the real core/thread layout, or job cgroups lose vCPUs."
  }

  assert {
    condition = output.nodes == {
      head      = "10.42.1.10"
      compute-1 = "10.42.1.11"
      compute-2 = "10.42.1.12"
      compute-3 = "10.42.1.13"
    }
    error_message = "Node addresses must be the fixed IPs slurm.conf was rendered with."
  }
}

run "world_open_ssh_is_rejected" {
  command = plan

  variables {
    admin_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.admin_cidrs]
}

run "wide_admin_cidr_is_rejected" {
  command = plan

  variables {
    admin_cidrs = ["10.0.0.0/8"]
  }

  expect_failures = [var.admin_cidrs]
}
