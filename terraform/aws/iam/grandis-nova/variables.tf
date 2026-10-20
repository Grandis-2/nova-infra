variable "github_repositories" {
  description = "배포 역할을 받을 저장소 목록. OIDC sub 의 repo: 뒤 부분 (owner/repo, immutable subject 면 owner@id/repo@id)"
  type        = list(string)
}

variable "github_mock_repositories" {
  description = "mock 전용 배포 역할(github_deploy_mock.tf)을 받을 저장소. 형식은 github_repositories 와 같다"
  type        = list(string)
  default     = []
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

variable "db_migration" {
  description = "RDS 이전 기간의 역할 · 권한(ProxySQL 실행 역할, bastion 런북 권한)을 만든다 (db_migration.tf)"
  type        = bool
  default     = false
}
