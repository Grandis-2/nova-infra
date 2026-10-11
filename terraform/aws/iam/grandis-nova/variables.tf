variable "github_repositories" {
  description = "배포 역할을 받을 저장소 목록. OIDC sub 의 repo: 뒤 부분 (owner/repo, immutable subject 면 owner@id/repo@id)"
  type        = list(string)
}

variable "github_deploy_branches" {
  description = "배포를 허용할 ref. 기본은 main 브랜치뿐"
  type        = list(string)
  default     = ["refs/heads/main"]
}

variable "create_github_oidc_provider" {
  description = "계정에 GitHub OIDC 공급자가 이미 있으면 false"
  type        = bool
  default     = true
}
