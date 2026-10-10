# 모든 스택이 공유하는 이름 규칙 (각 스택 디렉터리에 심볼릭 링크)
locals {
  # nova-prod
  name_prefix = "${var.product}-${var.env}"

  # ap-northeast-2 -> apnortheast2 (S3 버킷 등 하이픈 없는 이름용)
  region_slug = replace(var.aws_region, "-", "")

  az_suffix = [for az in var.availability_zones : substr(az, -1, 1)] # ["a", "c"]
}
