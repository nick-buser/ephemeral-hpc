output "state_bucket" {
  description = "Pass to infra/ as -backend-config=\"bucket=...\"."
  value       = aws_s3_bucket.state.bucket
}

output "budget_name" {
  value = aws_budgets_budget.monthly.name
}
