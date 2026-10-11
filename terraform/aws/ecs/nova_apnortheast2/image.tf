# 서비스별 이미지 — application/<서비스>/service.yml 의 image_tag
#
#   없음 · latest : <저장소>:latest. be release 가 새 이미지를 올리고 force-new-deployment 하면 그걸로 배포된다
#   커밋 해시     : 앞 6자리 이상. ECR 에서 그 커밋의 전체 태그를 찾아 다이제스트로 고정한다.
#                   release 가 latest 를 옮겨도 이 서비스는 바뀌지 않는다 (되돌리기 · 고정)
#
# 바꾸면 새 태스크 정의 리비전이 생기고, 서비스는 제자리에서 갱신돼 Blue/Green(또는 롤링)으로 배포된다.

locals {
  pinned_images = { for k, v in local.deployed_services : k => v.image_tag if v.image_tag != "latest" }

}

data "aws_ecr_images" "pinned" {
  for_each = local.pinned_images

  repository_name = local.repository_names[each.key]
}

locals {
  # 접두사가 맞는 커밋 태그 (40자 해시만. latest · content-… 태그는 뺀다)
  pinned_tags = {
    for k, prefix in local.pinned_images : k => distinct([
      for id in data.aws_ecr_images.pinned[k].image_ids : id.image_tag
      if id.image_tag != null && can(regex("^[0-9a-f]{40}$", id.image_tag)) && startswith(id.image_tag, prefix)
    ])
  }
}

data "aws_ecr_image" "pinned" {
  for_each = local.pinned_images

  repository_name = local.repository_names[each.key]
  image_tag       = try(local.pinned_tags[each.key][0], "not-found")

  lifecycle {
    precondition {
      condition     = length(local.pinned_tags[each.key]) == 1
      error_message = "${each.key}: image_tag '${each.value}' 에 맞는 이미지가 ${length(local.pinned_tags[each.key])}개다 (1개여야 한다). ${local.repository_names[each.key]} 의 커밋 태그를 확인하고, 여러 개면 자릿수를 늘린다."
    }
  }
}

locals {
  service_images = {
    for k, v in local.deployed_services : k => (
      contains(keys(local.pinned_images), k)
      ? "${local.repository_urls[k]}@${data.aws_ecr_image.pinned[k].image_digest}"
      : "${local.repository_urls[k]}:latest"
    )
  }
}
