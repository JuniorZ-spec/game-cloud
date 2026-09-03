variable "name" {
  description = "Préfixe utilisé pour nommer toutes les ressources réseau."
  type        = string
  default     = "gamecloud"
}

variable "cluster_name" {
  description = "Nom du futur cluster EKS. Sert uniquement à taguer les subnets (kubernetes.io/cluster/<nom>) pour qu'EKS et l'AWS Load Balancer Controller les reconnaissent automatiquement plus tard."
  type        = string
  default     = "gamecloud-eks"
}

variable "vpc_cidr" {
  description = "Plage d'adresses IP du VPC entier."
  type        = string
  default     = "10.20.0.0/16"
}

variable "azs" {
  description = "3 zones de disponibilité (data centers distincts) dans eu-west-3."
  type        = list(string)
  default     = ["eu-west-3a", "eu-west-3b", "eu-west-3c"]
}

variable "public_subnet_cidrs" {
  description = "Un sous-réseau public par AZ (bastion, ALB)."
  type        = list(string)
  default     = ["10.20.0.0/24", "10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Un sous-réseau privé par AZ (nœuds EKS)."
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24", "10.20.12.0/24"]
}
