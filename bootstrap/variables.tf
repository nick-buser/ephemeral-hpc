variable "region" {
  description = "Region for the state bucket. Must match infra/."
  type        = string
  default     = "us-east-2"
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget; alerts fire at 50/80/100% actual and 100% forecast."
  type        = number
  default     = 20

  validation {
    condition     = var.monthly_budget_usd > 0 && var.monthly_budget_usd <= 200
    error_message = "Budget must be between 1 and 200 USD."
  }
}

variable "alert_email" {
  description = "Where budget alerts go. Pass via TF_VAR_alert_email; never commit it."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}
