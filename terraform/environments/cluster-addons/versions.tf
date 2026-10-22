terraform {
  required_version = ">= 1.10.0, < 2.0.0"
  backend "s3" {
    bucket       = "meeting-bot-tfstate-481665121849-ap-south-1"
    key          = "meeting-bot-platform/cluster-addons/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
  required_providers {
    aws        = { source = "hashicorp/aws", version = "= 5.98.0" }
    helm       = { source = "hashicorp/helm", version = "= 2.17.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "= 2.36.0" }
  }
}

data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "meeting-bot-tfstate-481665121849-ap-south-1"
    key    = "meeting-bot-platform/learning/terraform.tfstate"
    region = "ap-south-1"
  }
}

provider "aws" { region = data.terraform_remote_state.infra.outputs.region }

provider "kubernetes" {
  host                   = data.terraform_remote_state.infra.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.infra.outputs.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.infra.outputs.cluster_name, "--region", data.terraform_remote_state.infra.outputs.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.infra.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.infra.outputs.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.infra.outputs.cluster_name, "--region", data.terraform_remote_state.infra.outputs.region]
    }
  }
}
