# Two instance roles so each node gets only what it needs:
#   head    — publish the munge key to SSM Parameter Store, prune old ones
#   compute — read the munge key
# Both get AmazonSSMManagedInstanceCore for break-glass Session Manager access.
# The munge key is generated on the head node at boot and never passes
# through Terraform state, user data, or git (docs/adr/0004-secrets.md).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  param_prefix = "/${var.cluster_name}/"
  param_arn    = "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.cluster_name}/*"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "head" {
  name_prefix        = "${var.cluster_name}-head-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role" "compute" {
  name_prefix        = "${var.cluster_name}-compute-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each = {
    head    = aws_iam_role.head.name
    compute = aws_iam_role.compute.name
  }

  role       = each.value
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "head_secrets" {
  statement {
    sid = "PublishClusterKey"
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:GetParametersByPath",
    ]
    resources = [local.param_arn]
  }
}

data "aws_iam_policy_document" "compute_secrets" {
  statement {
    sid       = "ReadClusterKey"
    actions   = ["ssm:GetParameter"]
    resources = [local.param_arn]
  }
}

resource "aws_iam_role_policy" "head_secrets" {
  name   = "cluster-key-publish"
  role   = aws_iam_role.head.id
  policy = data.aws_iam_policy_document.head_secrets.json
}

resource "aws_iam_role_policy" "compute_secrets" {
  name   = "cluster-key-read"
  role   = aws_iam_role.compute.id
  policy = data.aws_iam_policy_document.compute_secrets.json
}

resource "aws_iam_instance_profile" "head" {
  name_prefix = "${var.cluster_name}-head-"
  role        = aws_iam_role.head.name
}

resource "aws_iam_instance_profile" "compute" {
  name_prefix = "${var.cluster_name}-compute-"
  role        = aws_iam_role.compute.name
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow.arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  name_prefix        = "${var.cluster_name}-flowlogs-"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}
