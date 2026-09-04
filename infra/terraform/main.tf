module "vpc" {
  source = "./modules/vpc"

  name         = var.project_name
  cluster_name = var.cluster_name
}

module "eks" {
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  aws_region         = var.aws_region
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
}

module "bastion" {
  source = "./modules/bastion"

  name             = var.project_name
  vpc_id           = module.vpc.vpc_id
  public_subnet_id = module.vpc.public_subnet_ids[0]
  cluster_name     = module.eks.cluster_name
  aws_region       = var.aws_region
}

# Autorise le rôle IAM du bastion à agir sur l'API Kubernetes du
# cluster (côté IAM, le bastion peut déjà appeler l'API EKS ; ceci
# lui donne en plus les droits Kubernetes eux-mêmes).
resource "aws_eks_access_entry" "bastion" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.bastion.role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.bastion.role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# Autorisation RESEAU (distincte de l'IAM et du RBAC Kubernetes
# ci-dessus) : le security group du control plane EKS doit
# explicitement accepter le trafic HTTPS venant du bastion.
resource "aws_security_group_rule" "eks_from_bastion" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_security_group_id
  source_security_group_id = module.bastion.security_group_id
  description              = "Autorise le bastion a atteindre l API Kubernetes privee"
}

module "ecr" {
  source = "./modules/ecr"
}

module "github_oidc" {
  source = "./modules/github-oidc"

  name                = var.project_name
  ecr_repository_arns = values(module.ecr.repository_arns)
}
