provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

provider "kubernetes" {
  host                   = var.deploy_k8s ? data.aws_eks_cluster.this[0].endpoint : ""
  cluster_ca_certificate = var.deploy_k8s ? base64decode(data.aws_eks_cluster.this[0].certificate_authority[0].data) : ""
  token                  = var.deploy_k8s ? data.aws_eks_cluster_auth.this[0].token : ""
}

# IMPORTANT: Helm provider expects "kubernetes = { ... }" in your setup (not a nested block)
provider "helm" {
  kubernetes = {
    host                   = var.deploy_k8s ? data.aws_eks_cluster.this[0].endpoint : ""
    cluster_ca_certificate = var.deploy_k8s ? base64decode(data.aws_eks_cluster.this[0].certificate_authority[0].data) : ""
    token                  = var.deploy_k8s ? data.aws_eks_cluster_auth.this[0].token : ""
  }
}
