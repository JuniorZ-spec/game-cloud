output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Endpoint de l'API Kubernetes. Privé : injoignable depuis Internet, seulement depuis l'intérieur du VPC."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority" {
  value     = aws_eks_cluster.this.certificate_authority[0].data
  sensitive = true
}

output "oidc_provider_arn" {
  description = "ARN du fournisseur OIDC, réutilisé en phase 6 (IRSA) pour créer des rôles IAM de confiance par service account."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.eks.url
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "image_updater_role_arn" {
  value = aws_iam_role.image_updater.arn
}

output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}

output "cluster_security_group_id" {
  description = "Security group géré automatiquement par EKS pour le control plane. Il faut y ajouter explicitement une règle pour que le bastion (ou tout autre client) puisse l'atteindre."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
