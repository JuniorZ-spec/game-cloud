output "instance_id" {
  value = aws_instance.bastion.id
}

output "role_arn" {
  description = "Réutilisé à la racine pour créer l'EKS Access Entry (autorisation côté Kubernetes, distincte de l'IAM)."
  value       = aws_iam_role.bastion.arn
}

output "security_group_id" {
  value = aws_security_group.bastion.id
}
