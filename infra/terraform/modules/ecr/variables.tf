variable "service_names" {
  description = "Un depot ECR par microservice."
  type        = list(string)
  default     = ["auth-api", "pendu-api", "quiz-api", "puissance4-api", "memory-api", "score-api", "frontend"]
}
