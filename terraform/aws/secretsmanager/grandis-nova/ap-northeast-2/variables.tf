variable "secret_versions" {
  description = <<-EOT
    생성 비밀의 버전. 번호를 올리면 그 비밀만 새 값으로 바꾼다 (기본 1).
    키: "<서비스>/<환경변수>", "shared/<이름>", "ops/grafana" (관측 호스트 Grafana admin) 또는 "ops/loadtest-header" (부하 시험 헤더). 예: { "member/JWT_PRIVATEKEY" = 2 }
    번호는 올리기만 한다. 줄이거나 키를 지우면(기본 1로 돌아감) 그 값이 이전과 달라 새 값으로 바뀐다.
    JWT 키를 바꾸면 기존 로그인 토큰이 모두 무효가 된다 — member 의 jwt.key-id 도 함께 바꾼다.
  EOT
  type        = map(number)
  default     = {}

  validation {
    condition     = alltrue([for v in values(var.secret_versions) : v >= 1 && floor(v) == v])
    error_message = "secret_versions 의 값은 1 이상의 정수여야 합니다."
  }
}
