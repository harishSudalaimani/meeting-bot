terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "= 5.98.0" }
    random = { source = "hashicorp/random", version = "= 3.7.1" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner_tag
    }
  }
}
