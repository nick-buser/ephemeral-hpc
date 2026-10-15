# Cost guardrails that live in AWS, not in anyone's memory:
#   - every node schedules its own power-off at boot (ttl_hours), and power-off
#     means terminate (instance_initiated_shutdown_behavior in compute.tf);
#   - a node whose peak CPU stays under 5% for idle_minutes is terminated by
#     a CloudWatch alarm action, with no Lambda or credentials involved;
#   - the account-level budget alerts live in bootstrap/.

locals {
  instances = merge(
    { head = aws_instance.head.id },
    { for name, inst in aws_instance.compute : name => inst.id },
  )
}

resource "aws_cloudwatch_metric_alarm" "idle_terminate" {
  for_each = local.instances

  alarm_name          = "${var.cluster_name}-${each.key}-idle"
  alarm_description   = "Terminate ${each.key} after ${var.idle_minutes} idle minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = each.value }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = var.idle_minutes / 5
  threshold           = 5
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = ["arn:${data.aws_partition.current.partition}:automate:${var.region}:ec2:terminate"]
}

resource "aws_cloudwatch_dashboard" "cluster" {
  dashboard_name = var.cluster_name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "CPU by node (%)"
          region  = var.region
          view    = "timeSeries"
          stat    = "Average"
          period  = 60
          metrics = [for name, id in local.instances : ["AWS/EC2", "CPUUtilization", "InstanceId", id, { label = name }]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Network in by node (bytes)"
          region  = var.region
          view    = "timeSeries"
          stat    = "Sum"
          period  = 60
          metrics = [for name, id in local.instances : ["AWS/EC2", "NetworkIn", "InstanceId", id, { label = name }]]
        }
      },
    ]
  })
}
