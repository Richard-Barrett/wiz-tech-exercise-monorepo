terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
  backend "s3" {
    bucket  = "wiz-tech-terraform-state"
    key     = "wiz-tech-exercise/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
