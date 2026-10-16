# The in-OS shutdown scheduled at boot is the first TTL, but it lives on the
# machine it is meant to stop: anyone with root there can cancel it. This
# one runs in EventBridge Scheduler, outside every instance, and terminates
# each node ten minutes after the in-OS shutdown should have. Its role can
# terminate instances tagged for this cluster and do nothing else.

resource "time_static" "launched" {
  for_each = local.all_instance_ids
  triggers = { instance_id = each.value }
}

locals {
  all_instance_ids = merge(
    { head = aws_instance.head.id },
    { for name, inst in aws_instance.compute : name => inst.id },
  )
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "ttl_terminate" {
  statement {
    actions   = ["ec2:TerminateInstances"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Cluster"
      values   = [var.cluster_name]
    }
  }
}

resource "aws_iam_role" "ttl" {
  name_prefix        = "${var.cluster_name}-ttl-"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "ttl" {
  name   = "terminate-cluster-nodes"
  role   = aws_iam_role.ttl.id
  policy = data.aws_iam_policy_document.ttl_terminate.json
}

resource "aws_scheduler_schedule" "ttl" {
  for_each = local.all_instance_ids

  name_prefix                  = "${var.cluster_name}-ttl-${each.key}-"
  schedule_expression          = "at(${formatdate("YYYY-MM-DD'T'hh:mm:ss", timeadd(time_static.launched[each.key].rfc3339, "${local.ttl_minutes + 10}m"))})"
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:ec2:terminateInstances"
    role_arn = aws_iam_role.ttl.arn
    input    = jsonencode({ InstanceIds = [each.value] })

    retry_policy {
      maximum_retry_attempts       = 10
      maximum_event_age_in_seconds = 3600
    }
  }
}
