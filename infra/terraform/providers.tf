provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "gamecloud-aws-platform"
      ManagedBy = "terraform"
    }
  }
}
