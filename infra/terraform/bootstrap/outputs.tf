output "state_bucket_name" {
  description = "Nom du bucket S3 à réutiliser dans le backend.tf des autres modules."
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table_name" {
  description = "Nom de la table DynamoDB à réutiliser dans le backend.tf des autres modules."
  value       = aws_dynamodb_table.tflock.name
}
