# ============================================================
# Fournisseur OIDC pour GitHub Actions. Un seul fournisseur OIDC
# pour une URL donnee peut exister PAR COMPTE AWS (pas par projet) :
# ce compte en a deja un, cree par un autre projet (ticketbus). On
# le REFERENCE via une data source au lieu d'en creer un nouveau —
# creer un doublon echoue avec "EntityAlreadyExists".
# ============================================================
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ============================================================
# Role assume par GitHub Actions. La condition "sub" restreint
# l'usage a NOTRE depot precis : aucun autre repo GitHub, meme
# sur le meme compte AWS, ne peut assumer ce role.
# ============================================================
resource "aws_iam_role" "github_actions" {
  name = "${var.name}-github-actions-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
      }
    }]
  })
}

# Droits minimaux necessaires pour construire et pousser une image :
# recuperer un jeton d'authentification ECR (action globale, pas
# scopable a un repo precis) + operations de push scopees aux
# depots du projet uniquement.
resource "aws_iam_role_policy" "ecr_push" {
  name = "${var.name}-ecr-push"
  role = aws_iam_role.github_actions.id

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
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = var.ecr_repository_arns
      }
    ]
  })
}
