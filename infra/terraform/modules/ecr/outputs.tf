output "repository_urls" {
  description = "URL complete de chaque depot, reutilisee par le workflow CI pour savoir ou pousser."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  value = { for k, v in aws_ecr_repository.this : k => v.arn }
}
