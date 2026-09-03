output "role_arn" {
  description = "A coller dans le workflow GitHub Actions (role-to-assume)."
  value       = aws_iam_role.github_actions.arn
}
