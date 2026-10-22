data "aws_caller_identity" "current" {}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner_tag
  }
  api_hostname = "${var.api_subdomain}.${var.domain_name}"
}

module "networking" {
  source      = "../../modules/networking"
  name        = var.cluster_name
  region      = var.region
  common_tags = local.common_tags
}

module "data" {
  source      = "../../modules/data"
  name        = var.cluster_name
  common_tags = local.common_tags
}

module "eks" {
  source                        = "../../modules/eks"
  name                          = var.cluster_name
  region                        = var.region
  kubernetes_version            = var.kubernetes_version
  admin_cidrs                   = var.admin_cidrs
  private_subnet_ids            = module.networking.private_subnet_ids
  vpc_id                        = module.networking.vpc_id
  project                       = var.project
  common_tags                   = local.common_tags
  api_repository                = var.github_repository
  workload_artifact_arn         = module.data.artifact_bucket_arn
  dynamodb_table_arn            = module.data.jobs_table_arn
  request_queue_arn             = module.data.request_queue_arn
  delivery_queue_arn            = module.data.delivery_queue_arn
  request_queue_url             = module.data.request_queue_url
  delivery_queue_url            = module.data.delivery_queue_url
  artifact_bucket_name          = module.data.artifact_bucket_name
  hosted_zone_id                = var.hosted_zone_id
  github_oidc_provider_arn      = var.github_oidc_provider_arn
  delivery_destination_role_arn = var.delivery_destination_role_arn
  delivery_bucket               = var.delivery_bucket
}

module "edge" {
  source         = "../../modules/edge"
  name           = var.cluster_name
  domain_name    = var.domain_name
  api_hostname   = local.api_hostname
  hosted_zone_id = var.hosted_zone_id
  common_tags    = local.common_tags
}

module "observability" {
  source             = "../../modules/observability"
  name               = var.cluster_name
  request_queue_name = module.data.request_queue_name
  request_dlq_name   = module.data.request_dlq_name
  common_tags        = local.common_tags
  project            = var.project
  monthly_budget_usd = var.monthly_budget_usd
  budget_alert_email = var.budget_alert_email
}

