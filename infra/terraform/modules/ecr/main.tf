# Un depot ECR par microservice. scan_on_push : AWS lance aussi son
# propre scan de vulnerabilites basique a chaque push (en plus de
# Trivy dans la CI, une deuxieme couche de verification).
resource "aws_ecr_repository" "this" {
  for_each = toset(var.service_names)

  name                 = "gamecloud/${each.value}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Service = each.value
  }
}

# Evite une accumulation infinie d'images (donc de cout de stockage) :
# ne garde que les 10 dernieres images par service.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Garder seulement les 10 dernieres images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
