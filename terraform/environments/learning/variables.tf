variable "region" {
  description = "AWS region for the learning environment."
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  type    = string
  default = "meeting-bot-platform"
}

variable "environment" {
  type    = string
  default = "learning"
}

variable "owner_tag" {
  description = "Human or team name used for cost allocation; never a credential."
  type        = string
  default     = "learning"
}

variable "cluster_name" {
  type    = string
  default = "meeting-bot-learning"
}

variable "kubernetes_version" {
  description = "Pin to a currently supported EKS version after checking the region."
  type        = string
  default     = "1.36"
}

variable "admin_cidrs" {
  description = "Public IPv4 CIDRs allowed to reach the EKS Kubernetes API endpoint. Set to your current public /32."
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for cidr in var.admin_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Set admin_cidrs to at least one trusted IPv4 CIDR, usually your current public address with /32."
  }
}

variable "hosted_zone_id" {
  description = "ID of the existing public Route 53 hosted zone. The zone itself is never managed or deleted."
  type        = string
}

variable "domain_name" {
  description = "Existing domain served by hosted_zone_id, e.g. example.com."
  type        = string
}

variable "api_subdomain" {
  description = "Dedicated hostname label for the API. Only this hostname is published."
  type        = string
  default     = "api"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.api_subdomain))
    error_message = "api_subdomain must be one DNS label containing lowercase letters, digits, or hyphens."
  }
}

variable "github_repository" {
  description = "Optional owner/repository allowed to assume the CI publish role, e.g. acme/meeting-bot-platform. Empty disables that role."
  type        = string
  default     = ""
}

variable "github_oidc_provider_arn" {
  description = "Optional existing token.actions.githubusercontent.com OIDC provider ARN. If empty and CI is enabled, Terraform creates one."
  type        = string
  default     = ""
}

variable "delivery_destination_role_arn" {
  description = "Optional exact IAM role ARN trusted by a customer bucket owner for S3-to-S3 delivery. Leave empty to disable delivery."
  type        = string
  default     = ""
}

variable "delivery_destination_account_id" {
  description = "Expected AWS account ID that owns the optional customer delivery bucket."
  type        = string
  default     = ""
}

variable "delivery_bucket" {
  description = "Optional customer-owned S3 destination bucket; requires delivery_destination_role_arn."
  type        = string
  default     = ""
  validation {
    condition     = var.delivery_bucket == "" || (var.delivery_destination_role_arn != "" && var.delivery_destination_account_id != "")
    error_message = "Set a destination role ARN and destination account ID when delivery_bucket is configured."
  }
}

variable "bot_max_nodes_cpu" {
  description = "Hard NodePool ceiling. 8 vCPU allows up to four t3a.large bot nodes."
  type        = string
  default     = "8"
}

variable "monthly_budget_usd" {
  description = "Monthly cost alert budget scoped to resources tagged with this project's Project tag. This alert does not stop spending."
  type        = number
  default     = 20
  validation {
    condition     = var.monthly_budget_usd >= 1
    error_message = "monthly_budget_usd must be at least 1 USD."
  }
}

variable "budget_alert_email" {
  description = "Optional email address for project budget alerts at 80% and 100%. Empty leaves the budget visible in AWS without email notifications."
  type        = string
  default     = ""
}
