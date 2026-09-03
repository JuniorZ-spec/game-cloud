variable "aws_region" {
  description = "Région AWS où créer le bucket S3 et la table DynamoDB."
  type        = string
  default     = "eu-west-3"
}

variable "state_bucket_name" {
  description = "Nom du bucket S3 pour le state Terraform. Doit être unique dans TOUT AWS (pas juste ce compte) : on inclut l'account ID pour garantir l'unicité."
  type        = string
  default     = "gamecloud-tfstate-915993062361-euw3"
}

variable "lock_table_name" {
  description = "Nom de la table DynamoDB utilisée pour le verrouillage du state."
  type        = string
  default     = "gamecloud-tfstate-lock"
}
