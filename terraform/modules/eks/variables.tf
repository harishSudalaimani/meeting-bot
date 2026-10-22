variable "name" { type = string }
variable "region" { type = string }
variable "kubernetes_version" { type = string }
variable "admin_cidrs" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "vpc_id" { type = string }
variable "project" { type = string }
variable "common_tags" { type = map(string) }
variable "api_repository" {
  description = "GitHub owner/repository trusted for the image-publish and Terraform-plan/apply OIDC roles."
  type        = string
}
variable "workload_artifact_arn" { type = string }
variable "dynamodb_table_arn" { type = string }
variable "request_queue_arn" { type = string }
variable "delivery_queue_arn" { type = string }
variable "request_queue_url" { type = string }
variable "delivery_queue_url" { type = string }
variable "artifact_bucket_name" { type = string }
variable "hosted_zone_id" { type = string }
variable "github_oidc_provider_arn" { type = string }
variable "delivery_destination_role_arn" { type = string }
variable "delivery_bucket" { type = string }
