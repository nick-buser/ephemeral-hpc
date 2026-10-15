variable "region" {
  type    = string
  default = "us-east-2"
}

variable "cluster_name" {
  description = "Slurm ClusterName; also prefixes every AWS resource name."
  type        = string
  default     = "ehpc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.cluster_name))
    error_message = "cluster_name: lowercase letters, digits and hyphens, 2-20 chars."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "compute_count" {
  description = "Number of Slurm compute nodes (the head node is extra)."
  type        = number
  default     = 3

  validation {
    condition     = var.compute_count >= 1 && var.compute_count <= 8
    error_message = "compute_count must be between 1 and 8."
  }
}

# Defaults are free-tier-eligible types for accounts created after 2025-07-15.
variable "head_instance_type" {
  type    = string
  default = "t3.small"
}

variable "compute_instance_type" {
  type    = string
  default = "m7i-flex.large"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to SSH to the head node. scripts/tf.sh passes the operator's /32."
  type        = list(string)

  validation {
    condition = length(var.admin_cidrs) > 0 && alltrue([
      for c in var.admin_cidrs : can(cidrhost(c, 0)) && try(tonumber(split("/", c)[1]) >= 24, false)
    ])
    error_message = "admin_cidrs must be non-empty, valid, and no wider than /24. 0.0.0.0/0 is never accepted."
  }
}

variable "ssh_public_key" {
  description = "Operator public key installed for the ubuntu user."
  type        = string

  validation {
    condition     = can(regex("^ssh-ed25519 [A-Za-z0-9+/=]+", var.ssh_public_key))
    error_message = "ssh_public_key must be an ed25519 public key."
  }
}

variable "ttl_hours" {
  description = "Dead man's switch: every node powers off (and so terminates) this long after boot."
  type        = number
  default     = 4

  validation {
    condition     = var.ttl_hours >= 1 && var.ttl_hours <= 12
    error_message = "ttl_hours must be between 1 and 12."
  }
}

variable "idle_minutes" {
  description = "A node whose peak CPU stays under 5% this long is terminated by a CloudWatch alarm."
  type        = number
  default     = 60

  validation {
    condition     = var.idle_minutes >= 15 && var.idle_minutes % 5 == 0
    error_message = "idle_minutes must be a multiple of 5, at least 15."
  }
}
