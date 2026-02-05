# Grant kubectl access via EKS Access Entries (newer model)
# Only create when deploy_k8s=true so bootstrap can run without k8s providers.
resource "aws_eks_access_entry" "admin" {
  count         = var.deploy_k8s ? 1 : 0
  cluster_name  = module.eks.cluster_name
  principal_arn = var.eks_admin_principal_arn

  # Optional: keep default username behavior
  # username = var.eks_admin_principal_arn

  depends_on = [module.eks]
}

resource "aws_eks_access_policy_association" "admin" {
  count         = var.deploy_k8s ? 1 : 0
  cluster_name  = module.eks.cluster_name
  principal_arn = var.eks_admin_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
