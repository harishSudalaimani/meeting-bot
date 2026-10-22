terraform {
  required_version = ">= 1.10.0, < 2.0.0"
  backend "s3" {
    bucket       = "meeting-bot-tfstate-481665121849-ap-south-1"
    key          = "meeting-bot-platform/learning/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
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
