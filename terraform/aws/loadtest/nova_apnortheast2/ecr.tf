# 이미지 저장소. nova-loadtest main 의 빌드(-loadtest-github-build)만 올린다.
# 태그 규칙은 ecr 스택과 같다: 커밋 해시 태그는 덮어쓸 수 없고, 빌드가 함께 올리는 latest 만 예외다.
# 작업 정의는 :latest 를 쓴다(RunTask 는 이미지를 바꾸지 못한다). 빌드는 시험이 돌고 있지 않을 때만 latest 를 옮긴다.
locals {
  loadtest_images = ["k6", "controller", "token-minter"]
}

resource "aws_ecr_repository" "loadtest" {
  for_each = toset(local.loadtest_images)

  name                 = "nova/loadtest-${each.key}"
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"
  force_delete         = false

  image_tag_mutability_exclusion_filter {
    filter      = "latest"
    filter_type = "WILDCARD"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Name = "${local.loadtest_name}-${each.key}" }
}

resource "aws_ecr_lifecycle_policy" "loadtest" {
  for_each = aws_ecr_repository.loadtest

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expire_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the latest ${var.image_retention_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.image_retention_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
