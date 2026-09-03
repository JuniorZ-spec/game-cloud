terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Pas de backend distant ici volontairement : ce module CREE le bucket S3 et la
  # table DynamoDB que tous les autres modules Terraform du projet utiliseront comme
  # backend. Son propre state reste local (terraform.tfstate dans ce dossier),
  # ignoré par git (.gitignore mis à jour en Phase 0).
}

provider "aws" {
  region = var.aws_region
}

# Bucket S3 : stocke le fichier terraform.tfstate de tous les autres modules
# (vpc, eks, bastion, github-oidc...). Versionné pour pouvoir revenir en arrière
# si un state se corrompt. Chiffré par défaut (SSE-S3).
resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  # Empêche une suppression accidentelle du bucket via `terraform destroy` tant
  # qu'on n'a pas explicitement retiré cette protection.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Project   = "gamecloud-aws-platform"
    ManagedBy = "terraform-bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Table DynamoDB : sert de verrou. Terraform y écrit une entrée le temps d'un
# `apply`/`plan`, ce qui empêche une deuxième exécution simultanée de corrompre
# le state. PAY_PER_REQUEST = facturé à l'usage réel, pas de coût fixe.
resource "aws_dynamodb_table" "tflock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project   = "gamecloud-aws-platform"
    ManagedBy = "terraform-bootstrap"
  }
}
