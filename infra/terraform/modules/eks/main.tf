data "aws_caller_identity" "current" {}

# ============================================================
# Rôle IAM du CLUSTER : l'identité qu'EKS utilise pour gérer les
# ressources AWS sous-jacentes (ENI dans les subnets, etc.).
# ============================================================
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ============================================================
# LE CLUSTER : le control plane Kubernetes managé par AWS.
# endpoint_public_access = false : personne depuis Internet ne
# peut atteindre l'API Kubernetes, seulement depuis l'intérieur
# du VPC (donc via le bastion, phase 1d).
# ============================================================
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  # API_AND_CONFIG_MAP : autorise les "EKS Access Entries" (méthode
  # moderne pour donner des droits Kubernetes à un rôle IAM, comme le
  # bastion) en plus de l'ancienne configmap aws-auth.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]

  tags = {
    Name = var.cluster_name
  }
}

# ============================================================
# Fournisseur OIDC : pas utilisé tout de suite, mais c'est la
# fondation technique d'IRSA (phase 6). Il permet à un rôle IAM
# de faire confiance aux tokens émis par CE cluster précis, sans
# qu'aucune clé AWS ne soit jamais stockée dans un pod.
# ============================================================
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

# ============================================================
# EBS CSI Driver : ni EKS ni le node group ne l'installent par
# defaut (contrairement a eksctl). Sans lui, aucun PersistentVolume
# ne peut etre provisionne -> les pods avec PVC (postgres) restent
# bloques en Pending indefiniment. IRSA : le pod du driver assume ce
# role via son ServiceAccount, aucune cle AWS necessaire.
# ============================================================
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi-driver"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  depends_on = [aws_eks_node_group.main]
}

# ============================================================
# IRSA pour ArgoCD Image Updater : lecture seule sur ECR (lister
# les tags disponibles pour detecter une nouvelle image). Assume
# via le ServiceAccount "argocd-image-updater" dans le namespace
# argocd. Aucune cle AWS stockee dans le pod.
# ============================================================
resource "aws_iam_role" "image_updater" {
  name = "${var.cluster_name}-argocd-image-updater"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:argocd:argocd-image-updater"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# ============================================================
# IRSA pour l AWS Load Balancer Controller : cree/gere les ALB en
# reponse aux objets Gateway API. Policy officielle AWS (fichier
# telecharge depuis le repo du projet, pas ecrite a la main).
# ============================================================
resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "${var.cluster_name}-alb-controller-policy"
  role   = aws_iam_role.alb_controller.id
  policy = file("${path.module}/iam-policy-alb-controller.json")
}

# ============================================================
# EKS Pod Identity : mecanisme plus recent qu IRSA, plus simple
# (pas de federation OIDC, juste une "association" namespace+
# service-account -> role IAM). Demontre ici sur un composant
# dedie, separe de l app, pour bien distinguer les deux mecanismes
# d identite demandes (IRSA deja utilise par EBS CSI, ALB
# Controller, Image Updater ; Pod Identity ici).
# ============================================================
resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_iam_role" "pod_identity_demo" {
  name = "${var.cluster_name}-pod-identity-demo"

  # Trust policy radicalement plus simple qu IRSA : pas d OIDC, pas
  # de condition sur un subject de token. L agent Pod Identity gere
  # lui-meme l association namespace/service-account -> role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "pod_identity_demo_ecr" {
  name = "${var.cluster_name}-pod-identity-demo-ecr-read"
  role = aws_iam_role.pod_identity_demo.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:DescribeRepositories", "ecr:ListImages"]
        Resource = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/gamecloud/*"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "demo" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "gamecloud"
  service_account = "pod-identity-demo"
  role_arn        = aws_iam_role.pod_identity_demo.arn

  depends_on = [aws_eks_addon.pod_identity]
}

resource "aws_iam_role_policy" "image_updater_ecr" {
  name = "${var.cluster_name}-image-updater-ecr-read"
  role = aws_iam_role.image_updater.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/gamecloud/*"
      }
    ]
  })
}

# ============================================================
# Rôle IAM des NŒUDS : permet à chaque instance EC2 de rejoindre
# le cluster, de gérer les IP réseau (CNI) et de tirer les images
# depuis ECR.
# ============================================================
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ============================================================
# LE NODE GROUP : les machines EC2 qui exécutent réellement les
# pods. Placées uniquement dans les subnets PRIVÉS.
# ============================================================
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-main"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  tags = {
    Name = "${var.cluster_name}-node"
  }
}
