variable "aws_region" {
  description = "Région AWS pour toute la plateforme."
  type        = string
  default     = "eu-west-3"
}

variable "project_name" {
  description = "Préfixe utilisé pour nommer les ressources."
  type        = string
  default     = "gamecloud"
}

variable "cluster_name" {
  description = "Nom du cluster EKS."
  type        = string
  default     = "gamecloud-eks"
}
