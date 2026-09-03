variable "name" {
  type    = string
  default = "gamecloud"
}

variable "github_repo" {
  description = "org/repo GitHub autorise a assumer ce role. Aucun autre repo ne pourra jamais l'utiliser."
  type        = string
  default     = "JuniorZ-spec/game-cloud"
}

variable "ecr_repository_arns" {
  description = "ARNs des depots ECR sur lesquels ce role peut pousser des images."
  type        = list(string)
}
