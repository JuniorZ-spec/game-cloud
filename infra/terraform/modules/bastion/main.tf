# ============================================================
# Rôle IAM du bastion. AmazonSSMManagedInstanceCore permet à
# l'agent SSM (déjà présent sur Amazon Linux 2023) de s'enregistrer
# et d'accepter des sessions "Session Manager" — AUCUN port SSH
# ouvert, AUCUNE paire de clés à gérer.
# ============================================================
resource "aws_iam_role" "bastion" {
  name = "${var.name}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Permet au bastion d'appeler `aws eks update-kubeconfig` (lecture
# des métadonnées du cluster). L'accès à l'API Kubernetes elle-même
# est autorisé séparément via un EKS Access Entry (racine du projet).
resource "aws_iam_role_policy" "eks_describe" {
  name = "${var.name}-bastion-eks-describe"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.name}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ============================================================
# Security group : AUCUNE règle entrante. SSM Session Manager
# fonctionne uniquement en connexion SORTANTE (le bastion appelle
# les endpoints SSM), donc pas besoin d'ouvrir le moindre port
# vers l'intérieur — surface d'attaque nulle depuis Internet.
# ============================================================
resource "aws_security_group" "bastion" {
  name        = "${var.name}-bastion-sg"
  description = "Bastion : aucune regle entrante, sortant libre (SSM + API EKS + Internet)."
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-bastion-sg"
  }
}

# Dernière AMI Amazon Linux 2023 officielle, toujours à jour
# automatiquement (pas d'AMI ID codé en dur).
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  # Installe kubectl au démarrage (aws-cli v2 est déjà présent sur
  # les AMI Amazon Linux 2023 récentes).
  user_data = <<-EOF
    #!/bin/bash
    curl -LO "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    su - ec2-user -c "aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region}"
  EOF

  tags = {
    Name = "${var.name}-bastion"
  }
}
