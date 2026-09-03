terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # State distant : utilise le bucket S3 + la table DynamoDB créés par
  # infra/terraform/bootstrap/. C'est ici que "le vrai Terraform" du projet
  # (VPC, EKS, bastion...) enregistre sa mémoire, contrairement au bootstrap
  # qui garde la sienne en local.
  backend "s3" {
    bucket         = "gamecloud-tfstate-915993062361-euw3"
    key            = "gamecloud/terraform.tfstate"
    region         = "eu-west-3"
    dynamodb_table = "gamecloud-tfstate-lock"
    encrypt        = true
  }
}
