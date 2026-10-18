# 이미지 저장소. 이름은 백엔드 CI(be release.yml 의 ECR_NAMESPACE)가 푸시하는 nova/<이름> 과 같아야 한다.
#   서비스마다 하나 (application/<서비스>/service.yml)
#   migration — Flyway 와 마이그레이션 SQL. release 가 배포 전에 마이그레이션 태스크로 돌린다 (ecs 스택 migration.tf)
#   mock-migration — mock 저장소의 Flyway(external_mock). mock release 가 올리고 돌린다 (NV-523)
# 배포는 커밋 SHA 태그를 쓰므로 태그를 덮어쓸 수 없게 하고, CI 가 함께 올리는 latest 만 예외로 둔다.
locals {
  repositories = merge(
    { for k, v in local.services : k => { name = v.name, image_tag = v.image_tag } },
    { migration = { name = "migration", image_tag = "latest" } },
    { mock-migration = { name = "mock-migration", image_tag = "latest" } },
  )
}

resource "aws_ecr_repository" "this" {
  for_each = local.repositories

  name                 = "${var.repository_namespace}/${each.value.name}"
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

  tags = { Name = "${local.name_prefix}-${each.value.name}" }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  # 먼저 걸린 규칙이 그 이미지를 차지한다 (뒤 규칙은 보지 않는다).
  # service.yml 의 image_tag 로 고정한 이미지는 "최근 N개" 규칙보다 앞에서 잡아 지워지지 않게 한다.
  # 커밋 해시는 접두사로, 버전 태그는 이름 그대로 맞춘다 — 접두사로 맞추면 0.0.3-r1 이 r10 · r11 까지 잡는다.
  # 버전 태그 정규식은 variables/locals_services.tf 의 형식 검사 · ecs 스택 image.tf 의 version_tag 와 같아야 한다
  policy = jsonencode({
    rules = concat(
      [{
        rulePriority = 1
        description  = "Expire untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expire_days
        }
        action = { type = "expire" }
      }],
      local.repositories[each.key].image_tag != "latest" ? [{
        rulePriority = 2
        description  = "Keep the image pinned by service.yml image_tag"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = [can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+-r[0-9]+$", local.repositories[each.key].image_tag)) ? local.repositories[each.key].image_tag : "${local.repositories[each.key].image_tag}*"]
          countType      = "imageCountMoreThan"
          countNumber    = 9999
        }
        action = { type = "expire" }
      }] : [],
      [{
        rulePriority = 3
        description  = "Keep only the latest ${var.image_retention_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.image_retention_count
        }
        action = { type = "expire" }
      }],
    )
  })
}

# Terraform 밖에서 만든 저장소는 이미지를 유지한 채 상태로 가져온다.
# 가져온 뒤에는 아무 동작도 하지 않고, 상태를 잃었을 때 다시 가져오는 데 쓴다.
import {
  for_each = { for k, v in local.repositories : k => v if contains(var.existing_repositories, "${var.repository_namespace}/${v.name}") }

  to = aws_ecr_repository.this[each.key]
  id = "${var.repository_namespace}/${each.value.name}"
}
