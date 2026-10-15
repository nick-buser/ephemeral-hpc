terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }

  # Bucket and region come from scripts/tf-run.sh (-backend-config), derived
  # from the caller's account so no account ID is committed. S3-native
  # locking (use_lockfile) replaces the DynamoDB lock table.
  backend "s3" {
    key          = "infra/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "ephemeral-hpc"
      Stack     = "infra"
      Cluster   = var.cluster_name
      ManagedBy = "terraform"
    }
  }
}
