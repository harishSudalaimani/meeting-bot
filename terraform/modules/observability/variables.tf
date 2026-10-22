variable "name" { type = string }
variable "request_queue_name" { type = string }
variable "request_dlq_name" { type = string }
variable "common_tags" { type = map(string) }
variable "project" { type = string }
variable "monthly_budget_usd" { type = number }
variable "budget_alert_email" { type = string }
