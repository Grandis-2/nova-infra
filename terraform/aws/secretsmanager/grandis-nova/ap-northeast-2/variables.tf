variable "secret_versions" {
  description = <<-EOT
    생성 비밀의 버전. 번호를 올리면 그 비밀만 새 값으로 바꾼다 (기본 1).
    키: "<서비스>/<환경변수>" 또는 "shared/<이름>". 예: { "member/JWT_PRIVATEKEY" = 2 }
    JWT 키를 바꾸면 기존 로그인 토큰이 모두 무효가 된다 — member 의 jwt.key-id 도 함께 바꾼다.
  EOT
  type        = map(number)
  default     = {}
}
