variable "cluster_name" {
  type = string
}

variable "kubernetes_version" {
  description = "Version de Kubernetes gérée par EKS."
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Subnets privés : c'est là que vivent les nœuds (jamais joignables directement depuis Internet)."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Subnets publics : inclus dans la config du cluster pour que le control plane puisse y placer des ENI si besoin (ALB futur), mais aucun nœud n'y est placé."
  type        = list(string)
}

variable "node_instance_types" {
  description = "Ce compte AWS restreint les instances EC2 aux types eligible-for-Free-Tier uniquement. m7i-flex.large (8 Go RAM) choisi pour avoir assez de marge mémoire pour Prometheus/ES/7 microservices plus tard."
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}
