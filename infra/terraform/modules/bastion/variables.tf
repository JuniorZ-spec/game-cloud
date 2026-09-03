variable "name" {
  type    = string
  default = "gamecloud"
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_id" {
  description = "Le bastion vit dans un subnet PUBLIC (a besoin d'une IP publique pour que SSM Session Manager puisse l'atteindre en sortie)."
  type        = string
}

variable "cluster_name" {
  description = "Nom du cluster EKS, pour pré-configurer le kubeconfig au démarrage du bastion."
  type        = string
}

variable "aws_region" {
  type    = string
  default = "eu-west-3"
}

variable "instance_type" {
  description = "t3.micro : éligible Free Tier sur ce compte, largement suffisant pour exécuter kubectl/aws-cli."
  type        = string
  default     = "t3.micro"
}
